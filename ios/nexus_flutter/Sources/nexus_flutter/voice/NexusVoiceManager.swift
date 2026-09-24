import AVFoundation
import CallKit
import Foundation
import PushKit
import UIKit

/**
 Self-built voice call control for iOS — NO third-party call libraries. The exact
 twin of Android's `NexusVoiceManager`: it owns the CallKit integration so incoming
 calls ring in the SYSTEM call UI (over the lock screen) and are answered NATIVELY,
 and owns the PushKit registry so a KILLED app is woken by an APNs VoIP push.

 Flow (mirrors the Android ConnectionService flow 1:1):
   APNs VoIP push -> `pushRegistry(_:didReceiveIncomingPushWith:)`
     -> `reportIncoming` -> CXProvider.reportNewIncomingCall
     -> system rings -> user answers -> `provider(_:perform: CXAnswerCallAction)`
     -> `onCallAnswer` up to Dart -> the main Flutter engine connects LiveKit media.

 Why no headless engine (Android's `NexusCallForegroundService`): a VoIP push
 LAUNCHES the iOS app process, so the Flutter engine is already running by the time
 the user answers. Android needs a foreground service because Telecom can answer a
 call in a process with no engine at all.

 Audio: CallKit owns the AVAudioSession lifecycle. We never activate it ourselves —
 `didActivate`/`didDeactivate` are forwarded to Dart, which gates LiveKit's audio
 engine (`AudioSessionManagementMode.externalCallSystem`).
 */
@objc public final class NexusVoiceManager: NSObject {

  @objc public static let shared = NexusVoiceManager()

  /// Native -> Dart event sink, set by `NexusPlugin`. Mirrors Android's
  /// `NexusCallEvents`. Events raised before Dart is ready are buffered.
  public var onEvent: ((String, [String: Any]) -> Void)?

  private var provider: CXProvider?
  private let callController = CXCallController()
  private var pushRegistry: PKPushRegistry?

  /// Live calls keyed by our call id (the Voice sessionId), so a Dart-side
  /// hangup / remote-end can drive the matching CallKit call. Android keeps the
  /// same map of `NexusConnection`s.
  private var callIds: [String: UUID] = [:]
  private var sessionIds: [UUID: String] = [:]
  /// Calls the user has ANSWERED — decides whether an end action reports as a
  /// `reject` (declined while ringing) or a `disconnect` (hung up), exactly like
  /// Android's separate `onReject` / `onDisconnect`.
  private var answered: Set<UUID> = []
  /// Metadata kept for the missed-call notification (the cancel push may carry none).
  private var callInfo: [String: (from: String, displayName: String?)] = [:]

  private let lock = NSRecursiveLock()

  /// The current PushKit VoIP token (hex), registered with the Voice control
  /// plane so the backend can ring this device when the app is killed.
  private(set) var voipToken: String?

  /// Dart has attached its listeners — until then, events are queued so a
  /// cold-launch "answer" is never dropped (Android buffers this in Dart).
  private var dartReady = false
  private var pending: [(String, [String: Any])] = []
  private var didWarnBackgroundModes = false

  // MARK: - Setup

  /// Register the CallKit provider and the PushKit VoIP registry. Idempotent —
  /// the twin of Android's `registerPhoneAccount`. Safe to call at plugin
  /// registration (app launch) AND again from Dart.
  @objc public func registerAccount() {
    ensureProvider()
    ensurePushRegistry()
    warnAboutMissingBackgroundModes()
  }

  /// Report host-app Info.plist gaps that produce behaviour nobody can debug from
  /// the symptom alone. Checked once, at registration.
  private func warnAboutMissingBackgroundModes() {
    guard !didWarnBackgroundModes else { return }
    didWarnBackgroundModes = true
    if !Self.hasAudioBackgroundMode {
      NSLog("[NexusVoice] UIBackgroundModes is missing \"audio\". Calls work while the app is on screen, but iOS SUSPENDS call audio the moment the screen locks or the user leaves the app — which is most of a real call. Add \"audio\" alongside \"voip\" in Info.plist.")
    }
  }

  /// Called when the Dart voice service has wired its listeners: flush anything
  /// that happened during a cold launch.
  func markDartReady() {
    lock.lock()
    dartReady = true
    let queued = pending
    pending.removeAll()
    lock.unlock()
    for (name, args) in queued { onEvent?(name, args) }
  }

  private func ensureProvider() {
    lock.lock()
    defer { lock.unlock() }
    guard provider == nil else { return }
    let config: CXProviderConfiguration
    if #available(iOS 14.0, *) {
      config = CXProviderConfiguration()
    } else {
      config = CXProviderConfiguration(localizedName: Self.appName)
    }
    config.supportsVideo = false
    config.maximumCallsPerCallGroup = 1
    config.maximumCallGroups = 1
    config.supportedHandleTypes = [.generic, .phoneNumber]
    // Log calls in the system Recents, so a missed call is visible there — the
    // iOS equivalent of Android's Telecom call log entry.
    config.includesCallsInRecents = true
    if let icon = UIImage(named: "NexusCallIcon") {
      config.iconTemplateImageData = icon.pngData()
    }
    let p = CXProvider(configuration: config)
    p.setDelegate(self, queue: nil) // main queue
    provider = p
  }

  /// Start receiving APNs VoIP pushes. Skipped (with a log) when the host app has
  /// not declared the `voip` background mode — PushKit is unusable without it and
  /// starting a registry would only produce a token the OS never pushes to.
  private func ensurePushRegistry() {
    lock.lock()
    defer { lock.unlock() }
    guard pushRegistry == nil else { return }
    guard Self.hasVoipBackgroundMode else {
      NSLog("[NexusVoice] UIBackgroundModes is missing \"voip\" — incoming calls cannot ring a backgrounded/killed app. Add it to Info.plist.")
      return
    }
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    pushRegistry = registry
  }

  static var hasVoipBackgroundMode: Bool { backgroundModes.contains("voip") }

  static var hasAudioBackgroundMode: Bool { backgroundModes.contains("audio") }

  private static var backgroundModes: [String] {
    Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
  }

  static var appName: String {
    (Bundle.main.object(forInfoDictionaryKey: "NexusCallAppName") as? String)
      ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? "Nexus"
  }

  // MARK: - Incoming

  /// Ask the OS to ring [callId] in the SYSTEM call UI. Safe from a
  /// background/killed context — CallKit owns the process lifetime while ringing.
  /// The twin of Android's `reportIncomingCall`.
  @objc public func reportIncoming(
    callId: String,
    from: String,
    displayName: String?,
    hasVideo: Bool = false,
    completion: ((Error?) -> Void)? = nil
  ) {
    guard !callId.isEmpty else { completion?(nil); return }
    ensureProvider()
    guard let provider = provider else { completion?(nil); return }

    let uuid = uuidFor(callId, createIfMissing: true)!
    lock.lock()
    callInfo[callId] = (from: from, displayName: displayName)
    lock.unlock()

    let update = CXCallUpdate()
    update.remoteHandle = Self.handle(for: from, fallback: callId)
    // CallKit shows `localizedCallerName` over the handle when present.
    let name = (displayName?.isEmpty == false) ? displayName! : (from.isEmpty ? Self.appName : from)
    update.localizedCallerName = name
    update.hasVideo = hasVideo
    update.supportsHolding = true
    update.supportsDTMF = true
    update.supportsGrouping = false
    update.supportsUngrouping = false

    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      if let error = error {
        NSLog("[NexusVoice] reportNewIncomingCall failed: \(error.localizedDescription)")
        self?.forget(callId: callId)
      }
      completion?(error)
    }
  }

  // MARK: - Ending

  /// End a call from the Dart side (local hangup) or because the remote left.
  /// The twin of Android's `endCall` -> `NexusConnection.endFromApp()`.
  @objc public func endCall(_ callId: String) {
    guard let uuid = uuidFor(callId, createIfMissing: false) else { return }
    provider?.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
    forget(callId: callId)
  }

  /// The caller cancelled before we answered → end the ring as MISSED (so it
  /// lands in the system Recents as a missed call) and leave a "Missed call"
  /// notification, like a native phone call. Twin of Android's `missedCall`.
  @objc public func missedCall(callId: String, from: String, displayName: String?) {
    guard !callId.isEmpty else { return }
    let known = uuidFor(callId, createIfMissing: false)
    let info = infoFor(callId)
    let resolvedFrom = from.isEmpty ? (info?.from ?? "") : from
    let resolvedName = (displayName?.isEmpty == false) ? displayName : info?.displayName

    if let uuid = known {
      provider?.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
    }
    NexusCallNotification.showMissed(callId: callId, from: resolvedFrom, displayName: resolvedName)
    forget(callId: callId)
  }

  // MARK: - Outgoing

  /// Start a native OUTGOING call entry. Unlike Android — where a self-managed
  /// outgoing Connection can auto-end and tear down a healthy call, so it is
  /// deliberately skipped — iOS REQUIRES this: under CallKit the audio session is
  /// only ever activated for a call CallKit knows about, so an unreported
  /// outbound call would have no audio at all.
  @objc public func reportOutgoing(callId: String, to: String, displayName: String?) {
    guard !callId.isEmpty else { return }
    ensureProvider()
    let uuid = uuidFor(callId, createIfMissing: true)!
    lock.lock()
    callInfo[callId] = (from: to, displayName: displayName)
    lock.unlock()

    let action = CXStartCallAction(call: uuid, handle: Self.handle(for: to, fallback: callId))
    action.isVideo = false
    action.contactIdentifier = (displayName?.isEmpty == false) ? displayName : nil
    callController.request(CXTransaction(action: action)) { [weak self] error in
      if let error = error {
        NSLog("[NexusVoice] startCall failed: \(error.localizedDescription)")
        self?.forget(callId: callId)
        return
      }
      self?.provider?.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
    }
  }

  /// Tell the OS the call connected (starts its timer / active-call UI). For an
  /// answered INCOMING call CallKit already did this when we fulfilled the answer
  /// action; this matters for outgoing calls.
  @objc public func reportConnected(_ callId: String) {
    guard let uuid = uuidFor(callId, createIfMissing: false) else { return }
    lock.lock()
    let wasAnswered = answered.contains(uuid)
    lock.unlock()
    if !wasAnswered {
      provider?.reportOutgoingCall(with: uuid, connectedAt: nil)
    }
  }

  // MARK: - Registry helpers

  private func uuidFor(_ callId: String, createIfMissing: Bool) -> UUID? {
    lock.lock()
    defer { lock.unlock() }
    if let existing = callIds[callId] { return existing }
    guard createIfMissing else { return nil }
    // Derive a STABLE uuid from the session id where possible, so the same call
    // reported twice (push re-delivery) maps to one CallKit call.
    let uuid = UUID(uuidString: callId) ?? UUID()
    callIds[callId] = uuid
    sessionIds[uuid] = callId
    return uuid
  }

  private func callId(for uuid: UUID) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return sessionIds[uuid]
  }

  private func infoFor(_ callId: String) -> (from: String, displayName: String?)? {
    lock.lock()
    defer { lock.unlock() }
    return callInfo[callId]
  }

  private func forget(callId: String) {
    lock.lock()
    defer { lock.unlock() }
    if let uuid = callIds.removeValue(forKey: callId) {
      sessionIds.removeValue(forKey: uuid)
      answered.remove(uuid)
    }
    callInfo.removeValue(forKey: callId)
  }

  private static func handle(for address: String, fallback: String) -> CXHandle {
    let value = address.isEmpty ? fallback : address
    let digits = CharacterSet(charactersIn: "+0123456789 -()")
    let isPhone = value.hasPrefix("+") && value.unicodeScalars.allSatisfy { digits.contains($0) }
    return CXHandle(type: isPhone ? .phoneNumber : .generic, value: value)
  }

  fileprivate func emit(_ name: String, _ args: [String: Any]) {
    lock.lock()
    let ready = dartReady && onEvent != nil
    if !ready {
      if pending.count < 20 { pending.append((name, args)) }
      lock.unlock()
      return
    }
    lock.unlock()
    onEvent?(name, args)
  }
}

// MARK: - CallKit

extension NexusVoiceManager: CXProviderDelegate {

  public func providerDidReset(_ provider: CXProvider) {
    // The system tore every call down (e.g. the provider was reset). Mirror
    // Android's destroy: clear state and tell Dart each call is gone.
    lock.lock()
    let ids = Array(callIds.keys)
    callIds.removeAll()
    sessionIds.removeAll()
    answered.removeAll()
    callInfo.removeAll()
    lock.unlock()
    for id in ids { emit("onCallDisconnect", ["callId": id]) }
  }

  public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard let callId = callId(for: action.callUUID) else { action.fail(); return }
    lock.lock()
    answered.insert(action.callUUID)
    lock.unlock()
    // Hand the call to Dart, which connects LiveKit media in the MAIN engine —
    // the same "answer in the app engine" path Android uses.
    emit("onCallAnswer", ["callId": callId])
    // Fulfil immediately: CallKit must not wait on the network. The audio session
    // arrives separately via `didActivate`.
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    guard let callId = callId(for: action.callUUID) else { action.fulfill(); return }
    lock.lock()
    let wasAnswered = answered.contains(action.callUUID)
    lock.unlock()
    // Declined while ringing vs hung up after answering — the same split Android
    // makes between `onReject` and `onDisconnect`.
    emit(wasAnswered ? "onCallDisconnect" : "onCallReject", ["callId": callId])
    forget(callId: callId)
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    if let callId = callId(for: action.callUUID) {
      emit("onCallMute", ["callId": callId, "value": action.isMuted])
    }
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    if let callId = callId(for: action.callUUID) {
      emit("onCallHold", ["callId": callId, "value": action.isOnHold])
    }
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
    if let callId = callId(for: action.callUUID) {
      emit("onCallDtmf", ["callId": callId, "value": action.digits])
    }
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    if let callId = callId(for: action.callUUID) {
      provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
      emit("onCallStart", ["callId": callId])
    }
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    NSLog("[NexusVoice] CallKit action timed out: \(type(of: action))")
  }

  /// CallKit activated the shared audio session. LiveKit runs in
  /// `externalCallSystem` mode and never activates it itself — Dart opens the
  /// audio engine here.
  public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    emit("onCallAudioSession", ["active": true])
  }

  public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    emit("onCallAudioSession", ["active": false])
  }
}

// MARK: - PushKit (VoIP)

extension NexusVoiceManager: PKPushRegistryDelegate {

  public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    voipToken = token
    emit("onVoipToken", ["token": token])
  }

  public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    voipToken = nil
  }

  public func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else { completion(); return }
    let data = payload.dictionaryPayload
    let callId = (data["sessionId"] as? String) ?? (data["session_id"] as? String) ?? ""
    let from = (data["from"] as? String) ?? (data["callerNumber"] as? String) ?? ""
    let name = data["callerName"] as? String
    let kind = (data["type"] as? String) ?? "incoming_call"

    guard !callId.isEmpty else {
      // iOS 13+ kills the app if a VoIP push does not report a call. Report a
      // throwaway one and end it immediately rather than being terminated.
      reportAndDiscard(completion: completion)
      return
    }

    // Forward the raw payload so the Dart side can build its call state (the
    // ring itself does NOT wait for Dart — CallKit is driven from here).
    var forwarded: [String: Any] = [:]
    for (k, v) in data { if let key = k as? String { forwarded[key] = v } }
    emit("onVoicePush", forwarded)

    if kind == "cancel_call" {
      // A VoIP push MUST result in a reported call (iOS 13+). Report it, then end
      // it as unanswered — that both satisfies the OS and clears a ring that is
      // already on screen, which is how a killed iOS app learns the caller gave up.
      let known = uuidFor(callId, createIfMissing: false) != nil
      if known {
        missedCall(callId: callId, from: from, displayName: name)
        completion()
      } else {
        reportIncoming(callId: callId, from: from, displayName: name) { [weak self] _ in
          self?.missedCall(callId: callId, from: from, displayName: name)
          completion()
        }
      }
      return
    }

    reportIncoming(callId: callId, from: from, displayName: name) { _ in completion() }
  }

  /// Satisfy the iOS 13+ "every VoIP push must report a call" rule for a payload
  /// we cannot act on.
  private func reportAndDiscard(completion: @escaping () -> Void) {
    ensureProvider()
    guard let provider = provider else { completion(); return }
    let uuid = UUID()
    let update = CXCallUpdate()
    update.localizedCallerName = Self.appName
    update.remoteHandle = CXHandle(type: .generic, value: Self.appName)
    provider.reportNewIncomingCall(with: uuid, update: update) { _ in
      provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
      completion()
    }
  }
}
