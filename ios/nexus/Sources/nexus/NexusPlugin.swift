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
      result([
        "osType": "ios",
        "osVersion": UIDevice.current.systemVersion,
        "deviceModel": UIDevice.current.model,
        "deviceKey": UIDevice.current.identifierForVendor?.uuidString as Any,
      ])
    case "startReplay":
      let args = call.arguments as? [String: Any]
      recorder?.start(recordingId: args?["recordingId"] as? String ?? "")
      result(nil)
    case "stopReplay":
      recorder?.stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
