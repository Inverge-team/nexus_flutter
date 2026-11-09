import CryptoKit
import DeviceCheck
import Flutter
import Foundation
import LocalAuthentication
import Security
import UserNotifications

/**
 Push Authentication — iOS native side.

 Each enrolled device holds TWO P-256 keys in the Secure Enclave:
  - PRESENCE key (`<prefix>_presence`): created with `.userPresence`, so the
    enclave refuses to sign until Face ID / Touch ID / the passcode succeeds for
    that very signature. Used for every interactive approval.
  - SILENT key (`<prefix>_silent`): no user action unlocks it; it answers silent
    approvals (in the background, after first unlock) and signs request proofs.

 Secure Enclave keys can't be certified by Apple directly, so enrollment adds an
 App Attest attestation over both key thumbprints (`clientDataHash`, computed in
 Dart) — a genuine instance of this app on a genuine Apple device made them.

 Key handles live in the Keychain (this-device-only, after-first-unlock); the
 private keys never leave the enclave. On the Simulator (no enclave) keys fall
 back to software and the server records them as such.
 */
enum NexusPushAuth {
  private static let service = "net.inverge.nexus.pushauth"

  static func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let prefix = args["prefix"] as? String ?? "nexus_push_auth"
    switch call.method {
    case "pushAuthSupported":
      result(unsupportedReason())
    case "pushAuthCreateKeys":
      do { result(try createKeys(prefix)) } catch let e as NSError where e.domain == "NexusPushAuth" {
        result(FlutterError(code: "unsupported", message: e.localizedDescription, details: e.userInfo["reason"]))
      } catch { result(FlutterError(code: "push_auth_key", message: "\(error)", details: nil)) }
    case "pushAuthKeyInfo":
      result(keyInfo(prefix))
    case "pushAuthDeleteKeys":
      deleteItem("\(prefix)_presence")
      deleteItem("\(prefix)_silent")
      result(nil)
    case "pushAuthSignSilent":
      let data = (args["data"] as? FlutterStandardTypedData)?.data ?? Data()
      do { result(FlutterStandardTypedData(bytes: try sign("\(prefix)_silent", data, context: nil))) } catch {
        result(FlutterError(code: "push_auth_sign", message: "\(error)", details: nil))
      }
    case "pushAuthSignPresence":
      let data = (args["data"] as? FlutterStandardTypedData)?.data ?? Data()
      let prompt = args["prompt"] as? [String: Any] ?? [:]
      signPresence(prefix, data, reason: (prompt["description"] as? String) ?? (prompt["title"] as? String) ?? "Approve", result)
    case "pushAuthAttest":
      guard #available(iOS 14.0, *) else { return result(nil) }
      let hash = (args["clientDataHash"] as? FlutterStandardTypedData)?.data ?? Data()
      attest(hash, result)
    case "pushAuthDismiss":
      let cid = args["cid"] as? String ?? ""
      let center = UNUserNotificationCenter.current()
      center.getDeliveredNotifications { notes in
        let ids = notes.filter { ($0.request.content.userInfo["cid"] as? String) == cid }.map { $0.request.identifier }
        center.removeDeliveredNotifications(withIdentifiers: ids)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: keys

  private static func unsupportedReason() -> String? {
    var error: NSError?
    // `.deviceOwnerAuthentication` = biometrics OR passcode: what `.userPresence` needs.
    if !LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return "no_screen_lock" }
    return nil
  }

  private static func createKeys(_ prefix: String) throws -> [String: Any] {
    if let reason = unsupportedReason() {
      throw NSError(domain: "NexusPushAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Push Authentication needs a device passcode", "reason": reason])
    }
    deleteItem("\(prefix)_presence")
    deleteItem("\(prefix)_silent")
    let presence = try makeKey("\(prefix)_presence", flags: [.privateKeyUsage, .userPresence])
    let silent = try makeKey("\(prefix)_silent", flags: [.privateKeyUsage])
    return ["presence": presence, "silent": silent]
  }

  private static func makeKey(_ alias: String, flags: SecAccessControlCreateFlags) throws -> [String: Any] {
    let blob: Data
    let pub: P256.Signing.PublicKey
    let hardware: String
    if SecureEnclave.isAvailable {
      guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, flags, nil) else {
        throw NSError(domain: "NexusPushAuth", code: 2, userInfo: [NSLocalizedDescriptionKey: "access control"])
      }
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
    return describe(pub, hardware)
  }

  private static func keyInfo(_ prefix: String) -> [String: Any]? {
    guard let p = readItem("\(prefix)_presence"), let s = readItem("\(prefix)_silent"),
          let pk = try? publicKey(p), let sk = try? publicKey(s) else { return nil }
    return ["presence": describe(pk.0, pk.1), "silent": describe(sk.0, sk.1), "presenceValid": true]
  }

  private static func describe(_ pub: P256.Signing.PublicKey, _ hardware: String) -> [String: Any] {
    let x963 = pub.x963Representation // 0x04 || X || Y
    return ["x": b64url(x963.subdata(in: 1..<33)), "y": b64url(x963.subdata(in: 33..<65)), "chain": [String](), "hardware": hardware]
  }

  private static func publicKey(_ blob: Data) throws -> (P256.Signing.PublicKey, String) {
    let tag = String(decoding: blob.prefix(3), as: UTF8.self)
    let body = blob.dropFirst(3)
    if tag == "se:" { return (try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body).publicKey, "secure_enclave") }
    return (try P256.Signing.PrivateKey(rawRepresentation: body).publicKey, "software")
  }

  /// ECDSA-SHA256, DER (Dart converts to JOSE). [context] carries the prompt reason for the presence key.
  private static func sign(_ alias: String, _ data: Data, context: LAContext?) throws -> Data {
    guard let blob = readItem(alias) else { throw NSError(domain: "NexusPushAuth", code: 3, userInfo: [NSLocalizedDescriptionKey: "not enrolled"]) }
    let tag = String(decoding: blob.prefix(3), as: UTF8.self)
    let body = blob.dropFirst(3)
    if tag == "se:" {
      return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body, authenticationContext: context).signature(for: data).derRepresentation
    }
    return try P256.Signing.PrivateKey(rawRepresentation: body).signature(for: data).derRepresentation
  }

  /// Face ID / Touch ID / passcode first (clean `LAError`s), then the enclave
  /// signs with THAT authenticated context — `.userPresence` accepts it, so
  /// there is exactly one prompt and the signature still needed the user.
  private static func signPresence(_ prefix: String, _ data: Data, reason: String, _ result: @escaping FlutterResult) {
    let ctx = LAContext()
    ctx.localizedCancelTitle = "Cancel"
    ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
      guard ok else {
        let code: String
        switch (error as? LAError)?.code {
        case .userCancel?, .appCancel?, .systemCancel?, .userFallback?: code = "cancelled"
        case .biometryLockout?: code = "lockout"
        case .passcodeNotSet?: code = "no_screen_lock"
        default: code = "failed"
        }
        return DispatchQueue.main.async { result(FlutterError(code: code, message: error.map { "\($0)" }, details: nil)) }
      }
      do {
        let der = try sign("\(prefix)_presence", data, context: ctx)
        DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: der)) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "failed", message: "\(error)", details: nil)) }
      }
    }
  }

  // MARK: App Attest (enrollment only — a fresh key, never reused)

  @available(iOS 14.0, *)
  private static func attest(_ clientDataHash: Data, _ result: @escaping FlutterResult) {
    let svc = DCAppAttestService.shared
    guard svc.isSupported else { return result(nil) }
    svc.generateKey { keyId, error in
      guard let keyId else { return DispatchQueue.main.async { result(nil) } }
      svc.attestKey(keyId, clientDataHash: clientDataHash) { attestation, _ in
        DispatchQueue.main.async {
          guard let attestation else { return result(nil) }
          result(["keyId": keyId, "attestation": attestation.base64EncodedString()])
        }
      }
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
