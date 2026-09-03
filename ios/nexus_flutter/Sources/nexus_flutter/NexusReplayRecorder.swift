import Foundation

/**
 Native session-replay recorder (iOS). The standalone Swift SDK (nexus-ios) fills
 this in: attach to the key window, serialize an rrweb-compatible full snapshot,
 then emit incremental snapshots/mutations + touch/scroll interactions, batching
 them to `sink`.

 For now this is a safe no-op so the plugin compiles and runs; wiring real capture
 happens in the dedicated Swift SDK.
 */
public final class NexusReplayRecorder {
  public typealias BatchSink = (_ recordingId: String, _ events: [Any]) -> Void

  private let sink: BatchSink
  private(set) var recordingId: String?
  private(set) var isRecording = false

  public init(sink: @escaping BatchSink) {
    self.sink = sink
  }

  public func start(recordingId: String) {
    self.recordingId = recordingId
    self.isRecording = true
    // TODO(nexus-ios): begin capture — full snapshot + incremental events.
  }

  public func stop() {
    self.isRecording = false
    // TODO(nexus-ios): flush + detach capture.
  }
}
