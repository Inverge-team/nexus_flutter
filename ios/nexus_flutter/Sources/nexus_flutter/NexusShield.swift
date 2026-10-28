import CryptoKit
import DeviceCheck
import Flutter
import Foundation
import Security

/**
 Nexus Shield — iOS native side.

 Two keys, both in the Secure Enclave:
  - the DEVICE key (CryptoKit `SecureEnclave.P256.Signing`) signs every DPoP
    proof. Its handle is kept in the Keychain (this-device-only); the private
    key itself never leaves the enclave.
  - the App Attest key (`DCAppAttestService`) is certified ONCE by Apple for this
    app's team + bundle id, then produces counter-checked assertions. App Attest
    keys can't sign arbitrary data, so each attestation/assertion commits to
    the device key's thumbprint through `clientDataHash` (computed in Dart).

 On the Simulator (no enclave, no App Attest) the device key falls back to a
 software key and App Attest reports unsupported — use a debug token there.
 */
enum NexusShield {
  private static let service = "net.inverge.nexus.shield"
  private static let appAttestKeyIdKey = "nexus_shield_app_attest_key_id"

  static func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let alias = args["alias"] as? String ?? "nexus_shield"
    switch call.method {
    case "shieldEnsureKey":
      do { result(try ensureKey(alias)) } catch { result(FlutterError(code: "shield_key", message: "\(error)", details: nil)) }
    case "shieldSign":
      let data = (args["data"] as? FlutterStandardTypedData)?.data ?? Data()
      do { result(FlutterStandardTypedData(bytes: try sign(alias, data))) } catch {
        result(FlutterError(code: "shield_sign", message: "\(error)", details: nil))
      }
    case "shieldDeleteKey":
      deleteItem(alias)
      result(nil)
    case "shieldAppAttestSupported":
      if #available(iOS 14.0, *) { result(DCAppAttestService.shared.isSupported) } else { result(false) }
    case "shieldAppAttest":
      guard #available(iOS 14.0, *) else {
        return result(FlutterError(code: "shield_app_attest", message: "iOS 14+ required", details: nil))
      }
      let hash = (args["clientDataHash"] as? FlutterStandardTypedData)?.data ?? Data()
      appAttest(clientDataHash: hash, forceAttest: args["forceAttest"] as? Bool ?? false, result)
    case "shieldAppAttestReset":
      UserDefaults.standard.removeObject(forKey: appAttestKeyIdKey)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: device key

  private static func ensureKey(_ alias: String) throws -> [String: Any] {
    if let stored = readItem(alias) {
      let (pub, hw) = try publicKey(from: stored)
      return keyInfo(pub, hardware: hw, created: false)
    }
    let blob: Data
    let hardware: String
    let pub: P256.Signing.PublicKey
    if SecureEnclave.isAvailable {
      let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil)!
      let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
      blob = Data("se:".utf8) + key.dataRepresentation
      pub = key.publicKey
      hardware = "secure_enclave"
    } else {
      let key = P256.Signing.PrivateKey()
      blob = Data("sw:".utf8) + key.rawRepresentation
      pub = key.publicKey
      hardware = "software"
    }
    try writeItem(alias, blob)
    return keyInfo(pub, hardware: hardware, created: true)
  }

  private static func keyInfo(_ pub: P256.Signing.PublicKey, hardware: String, created: Bool) -> [String: Any] {
    let x963 = pub.x963Representation // 0x04 || X || Y
    return [
      "x": b64url(x963.subdata(in: 1..<33)),
      "y": b64url(x963.subdata(in: 33..<65)),
      "chain": [String](),
      "hardware": hardware,
      "created": created,
    ]
  }

  private static func publicKey(from blob: Data) throws -> (P256.Signing.PublicKey, String) {
    let tag = String(decoding: blob.prefix(3), as: UTF8.self)
    let body = blob.dropFirst(3)
    if tag == "se:" { return (try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body).publicKey, "secure_enclave") }
    return (try P256.Signing.PrivateKey(rawRepresentation: body).publicKey, "software")
  }

  /// ECDSA-SHA256 (CryptoKit hashes with SHA-256), DER — Dart converts to JOSE.
  private static func sign(_ alias: String, _ data: Data) throws -> Data {
    guard let blob = readItem(alias) else { throw NSError(domain: "NexusShield", code: 1, userInfo: [NSLocalizedDescriptionKey: "no key"]) }
    let tag = String(decoding: blob.prefix(3), as: UTF8.self)
    let body = blob.dropFirst(3)
    if tag == "se:" { return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body).signature(for: data).derRepresentation }
    return try P256.Signing.PrivateKey(rawRepresentation: body).signature(for: data).derRepresentation
  }

  // MARK: App Attest

  @available(iOS 14.0, *)
  private static func appAttest(clientDataHash: Data, forceAttest: Bool, _ result: @escaping FlutterResult) {
    let svc = DCAppAttestService.shared
    guard svc.isSupported else { return result(FlutterError(code: "shield_app_attest", message: "unsupported", details: nil)) }
    let reply: ([String: Any]?, Error?) -> Void = { value, error in
      DispatchQueue.main.async {
        if let value { result(value) } else {
          result(FlutterError(code: "shield_app_attest", message: error.map { "\($0)" } ?? "failed", details: nil))
        }
      }
    }
    let attestNew: () -> Void = {
      svc.generateKey { keyId, error in
        guard let keyId else { return reply(nil, error) }
        svc.attestKey(keyId, clientDataHash: clientDataHash) { attestation, error in
          guard let attestation else { return reply(nil, error) }
          UserDefaults.standard.set(keyId, forKey: appAttestKeyIdKey)
          reply(["keyId": keyId, "attestation": attestation.base64EncodedString(), "mode": "attestation"], nil)
        }
      }
    }
    guard !forceAttest, let keyId = UserDefaults.standard.string(forKey: appAttestKeyIdKey) else { return attestNew() }
    svc.generateAssertion(keyId, clientDataHash: clientDataHash) { assertion, error in
      if let assertion { return reply(["keyId": keyId, "assertion": assertion.base64EncodedString(), "mode": "assertion"], nil) }
      // The key is gone (app reinstalled from backup, OS reset): attest a new one.
      if let e = error as? DCError, e.code == .invalidKey {
        UserDefaults.standard.removeObject(forKey: appAttestKeyIdKey)
        return attestNew()
      }
      reply(nil, error)
    }
  }

  // MARK: keychain

  private static func query(_ alias: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: alias]
  }

  private static func readItem(_ alias: String) -> Data? {
    var q = query(alias)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
  }

  private static func writeItem(_ alias: String, _ data: Data) throws {
    deleteItem(alias)
    var q = query(alias)
    q[kSecValueData as String] = data
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(q as CFDictionary, nil)
    if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }

  private static func deleteItem(_ alias: String) {
    SecItemDelete(query(alias) as CFDictionary)
  }

  private static func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
