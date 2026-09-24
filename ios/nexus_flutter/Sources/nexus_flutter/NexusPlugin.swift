import AVFoundation
import Flutter
import UIKit

/**
 Flutter <-> iOS bridge. Serves device/app context; session-replay capture is
 delegated to the native core recorder (`NexusReplayRecorder`), which pushes
 rrweb-compatible event batches back up over the `onReplayBatch` channel; and
 native calling is delegated to `NexusVoiceManager` (CallKit + PushKit), the
 twin of Android's `NexusVoiceManager` + ConnectionService stack.
 */
public class NexusPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?
  private var recorder: NexusReplayRecorder?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "nexus", binaryMessenger: registrar.messenger())
    let instance = NexusPlugin()
    instance.channel = channel
    instance.recorder = NexusReplayRecorder { [weak channel] recordingId, events in
      DispatchQueue.main.async {
        channel?.invokeMethod("onReplayBatch", arguments: ["recordingId": recordingId, "events": events])
      }
    }
    registrar.addMethodCallDelegate(instance, channel: channel)

    // Native call events (answer / reject / disconnect / audio session / VoIP
    // push) -> Dart, mirroring the Android plugin's `NexusCallEvents` bridge.
    NexusVoiceManager.shared.onEvent = { [weak channel] name, args in
      DispatchQueue.main.async { channel?.invokeMethod(name, arguments: args) }
    }
    // PushKit must be live from LAUNCH: when a VoIP push wakes a killed app, the
    // registry has to exist before iOS delivers it. Plugin registration runs in
    // `didFinishLaunching`, which is the earliest hook a plugin gets. Apps that
    // don't declare the `voip` background mode are skipped inside.
    if NexusVoiceManager.hasVoipBackgroundMode {
      NexusVoiceManager.shared.registerAccount()
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "deviceInfo":
      result(deviceInfo())
    case "startReplay":
      let args = call.arguments as? [String: Any]
      recorder?.start(recordingId: args?["recordingId"] as? String ?? "")
      result(nil)
    case "stopReplay":
      recorder?.stop()
      result(nil)
    case "configureCrashReporting":
      let args = call.arguments as? [String: Any]
      if (args?["enabled"] as? Bool) == true { NexusCrashReporter.shared.install() }
      result(nil)
    case "takePendingCrashes":
      result(NexusCrashReporter.shared.takePending())
    case "liveActivityStart", "liveActivityUpdate", "liveActivityEnd", "liveActivityObservePushToStart":
      handleLiveActivity(call, result)
    case "voiceRegisterAccount", "voiceReportIncoming", "voiceEndCall", "voiceMissedCall",
         "voiceReportOutgoing", "voiceReportConnected", "voiceVoipToken":
      handleVoice(call, result)
    case "appIsForeground":
      // Authoritative: a VoIP push launches the app in the BACKGROUND, where no
      // permission dialog can ever be presented.
      onMain { result(UIApplication.shared.applicationState != .background) }
    case "micPermissionStatus":
      result(Self.micPermissionStatus())
    case "micRequestPermission":
      requestMicrophoneAccess(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Native calling — the iOS side of the SAME method-channel contract Android
  /// implements, so the Dart voice service drives both platforms identically.
  private func handleVoice(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let voice = NexusVoiceManager.shared
    switch call.method {
    case "voiceRegisterAccount":
      voice.registerAccount()
      // Dart has wired its listeners — release anything buffered during a
      // cold launch (e.g. the user answered before the engine was up).
      voice.markDartReady()
      result(nil)
    case "voiceReportIncoming":
      voice.reportIncoming(
        callId: args["callId"] as? String ?? "",
        from: args["from"] as? String ?? "",
        displayName: args["displayName"] as? String,
        hasVideo: args["hasVideo"] as? Bool ?? false
      )
      result(nil)
    case "voiceEndCall":
      voice.endCall(args["callId"] as? String ?? "")
      result(nil)
    case "voiceMissedCall":
      voice.missedCall(
        callId: args["callId"] as? String ?? "",
        from: args["from"] as? String ?? "",
        displayName: args["displayName"] as? String
      )
      result(nil)
    case "voiceReportOutgoing":
      voice.reportOutgoing(
        callId: args["callId"] as? String ?? "",
        to: args["to"] as? String ?? "",
        displayName: args["displayName"] as? String
      )
      result(nil)
    case "voiceReportConnected":
      voice.reportConnected(args["callId"] as? String ?? "")
      result(nil)
    case "voiceVoipToken":
      result(voice.voipToken)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleLiveActivity(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    #if os(iOS)
      if #available(iOS 16.1, *) {
        let mgr = NexusLiveActivityManager.shared
        mgr.onToken = { [weak channel] info in
          DispatchQueue.main.async { channel?.invokeMethod("onLiveActivityToken", arguments: info) }
        }
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "liveActivityStart":
          mgr.start(
            activityId: args["activityId"] as? String ?? "",
            activityType: args["activityType"] as? String ?? "",
            contentState: args["contentState"] as? [String: Any],
            attributes: args["attributes"] as? [String: Any]
          )
        case "liveActivityUpdate":
          mgr.update(activityId: args["activityId"] as? String ?? "", contentState: args["contentState"] as? [String: Any])
        case "liveActivityEnd":
          mgr.end(activityId: args["activityId"] as? String ?? "", contentState: args["contentState"] as? [String: Any])
        case "liveActivityObservePushToStart":
          mgr.observePushToStart(activityType: args["activityType"] as? String ?? "")
        default: break
        }
        result(nil)
        return
      }
    #endif
    result(nil) // Live Activities unavailable — no-op
  }

  /// The REAL microphone authorization, which `permission_handler` cannot express:
  /// it maps `.notDetermined` to "denied", and reports `permanentlyDenied` for any
  /// request that returns false — including a request made from the background,
  /// where iOS shows no dialog and refuses by default without recording a denial.
  /// Telling "never asked" apart from "refused" is the difference between
  /// prompting at the next opportunity and wrongly giving up forever.
  private static func micPermissionStatus() -> String {
    // A missing NSMicrophoneUsageDescription is FATAL, not merely restrictive:
    // `authorizationStatus` still reports `.notDetermined` and `requestAccess`
    // quietly returns false, but the first REAL microphone access (the WebRTC
    // audio engine opening its input) aborts the process through TCC
    // (__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__). Report it so the SDK can keep
    // the mic shut instead of taking the app down with it.
    if Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") == nil {
      return "missing_usage_description"
    }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "granted"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "undetermined"
    @unknown default: return "undetermined"
    }
  }

  /// Ask iOS for the microphone, through the OS API itself.
  ///
  /// Deliberately NOT delegated to a permission package: on iOS those report
  /// "never asked" as denied, report a failed request as a PERMANENT denial, and
  /// can be compiled out entirely by a Podfile flag — in which case they answer
  /// "denied" without the OS ever being asked, and the permission never even
  /// appears in Settings. A calling SDK cannot afford that ambiguity.
  ///
  /// Refuses to ask when it would be pointless or harmful: with no usage
  /// description the request is what kills the app, and in the background iOS
  /// cannot present the dialog and refuses instantly.
  private func requestMicrophoneAccess(_ result: @escaping FlutterResult) {
    let status = Self.micPermissionStatus()
    if status == "granted" { result(true); return }
    if status != "undetermined" { result(false); return }
    onMain {
      guard UIApplication.shared.applicationState != .background else {
        NSLog("[NexusVoice] microphone request skipped — the app is in the background, where iOS shows no dialog.")
        result(false)
        return
      }
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { result(granted) }
      }
    }
  }

  private func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }

  private func deviceInfo() -> [String: Any] {
    var info: [String: Any] = [
      "osType": "ios",
      "osVersion": UIDevice.current.systemVersion,
      "deviceModel": UIDevice.current.model,
      "deviceKey": UIDevice.current.identifierForVendor?.uuidString as Any,
    ]
    // iOS exposes no public install-date API — approximate: the app container's
    // creation date ~= install time; the executable's modification date ~= update.
    let fm = FileManager.default
    if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
       let attrs = try? fm.attributesOfItem(atPath: docs.path),
       let created = attrs[.creationDate] as? Date {
      info["installTime"] = Int(created.timeIntervalSince1970 * 1000)
    }
    if let exe = Bundle.main.executablePath,
       let attrs = try? fm.attributesOfItem(atPath: exe),
       let modified = attrs[.modificationDate] as? Date {
      info["updateTime"] = Int(modified.timeIntervalSince1970 * 1000)
    }
    return info
  }
}
