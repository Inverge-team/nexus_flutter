import Flutter
import UIKit

/**
 Flutter <-> iOS bridge. Serves device/app context; session-replay capture is
 delegated to the native core recorder (`NexusReplayRecorder`), which pushes
 rrweb-compatible event batches back up over the `onReplayBatch` channel.
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
    default:
      result(FlutterMethodNotImplemented)
    }
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
