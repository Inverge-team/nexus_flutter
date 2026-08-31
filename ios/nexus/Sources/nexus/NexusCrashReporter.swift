import Foundation

/**
 Catches uncaught Objective-C exceptions and fatal signals (SIGABRT/SIGSEGV/…),
 persists them to disk, and returns them on the next launch — a crashing process
 can't reliably make a network call, so the Flutter SDK forwards them on start.

 Note: signal handlers here do minimal work; a production-grade crash reporter
 (async-signal-safe, symbolicated) is the job of the dedicated iOS SDK. This is a
 functional starting point.
 */
final class NexusCrashReporter {
  static let shared = NexusCrashReporter()

  private var installed = false
  private let fileURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return dir.appendingPathComponent("nexus_crashes.log")
  }()

  func install() {
    guard !installed else { return }
    installed = true
    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    NSSetUncaughtExceptionHandler { exception in
      NexusCrashReporter.shared.persist(
        type: exception.name.rawValue,
        message: exception.reason ?? "Uncaught exception",
        frames: exception.callStackSymbols)
    }

    for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
      signal(sig) { s in
        NexusCrashReporter.shared.persist(
          type: "Signal", message: "Fatal signal \(s)", frames: Thread.callStackSymbols)
        signal(s, SIG_DFL)
        raise(s)
      }
    }
  }

  private func persist(type: String, message: String, frames: [String]) {
    let obj: [String: Any] = [
      "type": type,
      "message": message,
      "platform": "ios",
      "timestamp": Int(Date().timeIntervalSince1970 * 1000),
      "stack": frames,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    var line = data
    line.append(0x0A) // '\n'
    if let handle = try? FileHandle(forWritingTo: fileURL) {
      handle.seekToEndOfFile()
      handle.write(line)
      try? handle.close()
    } else {
      try? line.write(to: fileURL)
    }
  }

  func takePending() -> [[String: Any]] {
    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
    try? FileManager.default.removeItem(at: fileURL)
    var out: [[String: Any]] = []
    for line in content.split(separator: "\n") {
      if let d = line.data(using: .utf8),
         let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
        out.append(obj)
      }
    }
    return out
  }
}
