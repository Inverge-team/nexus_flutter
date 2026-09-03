import Foundation
import MachO

/**
 Catches uncaught Objective-C exceptions and fatal signals, persists them to
 disk, and returns them on the next launch. Captures **symbolication-ready**
 data: structured frames (module + address + symbol/offset) plus the loaded
 binary images (name, UUID, load address) so the backend can fully symbolicate
 stripped release builds with the matching dSYM.

 Note: signal handlers do minimal work (backtrace + write). A fully
 async-signal-safe, mach-exception-based reporter (e.g. PLCrashReporter) is the
 gold standard; this captures the essentials without an external dependency.
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
        symbols: exception.callStackSymbols)
    }

    for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
      signal(sig) { s in
        NexusCrashReporter.shared.persist(
          type: "Signal (\(NexusCrashReporter.signalName(s)))",
          message: "Fatal signal \(s)",
          symbols: Thread.callStackSymbols)
        signal(s, SIG_DFL)
        raise(s)
      }
    }
  }

  // MARK: - persistence

  private func persist(type: String, message: String, symbols: [String]) {
    let obj: [String: Any] = [
      "type": type,
      "message": message,
      "platform": "ios",
      "timestamp": Int(Date().timeIntervalSince1970 * 1000),
      "stack": symbols.map(Self.parseFrame),
      "binaryImages": Self.binaryImages(),
      "arch": Self.arch(),
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

  // MARK: - symbolication helpers

  /// Parse a `callStackSymbols` line: "<n> <module> <address> <symbol> + <offset>".
  static func parseFrame(_ line: String) -> [String: Any] {
    let parts = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    guard parts.count >= 4 else { return ["function": line] }
    var frame: [String: Any] = ["module": parts[1], "address": parts[2]]
    if let plus = parts.firstIndex(of: "+"), plus + 1 < parts.count {
      frame["function"] = parts[3..<plus].joined(separator: " ")
      if let off = Int(parts[plus + 1]) { frame["offset"] = off }
    } else {
      frame["function"] = parts[3...].joined(separator: " ")
    }
    return frame
  }

  /// Loaded images with UUID + load address — the backend matches these to dSYMs.
  static func binaryImages() -> [[String: Any]] {
    var images: [[String: Any]] = []
    for i in 0..<_dyld_image_count() {
      guard let namePtr = _dyld_get_image_name(i), let header = _dyld_get_image_header(i) else { continue }
      images.append([
        "name": String(cString: namePtr),
        // hex string — 64-bit addresses lose precision as a JSON number
        "loadAddress": String(format: "0x%lx", UInt(bitPattern: header)),
        "slide": _dyld_get_image_vmaddr_slide(i),
        "uuid": uuid(for: header) ?? "",
      ])
    }
    return images
  }

  /// Walk the mach-o load commands for LC_UUID.
  private static func uuid(for header: UnsafePointer<mach_header>) -> String? {
    let is64 = header.pointee.magic == MH_MAGIC_64 || header.pointee.magic == MH_CIGAM_64
    var cursor = UnsafeRawPointer(header).advanced(by: is64 ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size)
    for _ in 0..<header.pointee.ncmds {
      let cmd = cursor.assumingMemoryBound(to: load_command.self).pointee
      if cmd.cmd == LC_UUID {
        let u = cursor.assumingMemoryBound(to: uuid_command.self).pointee.uuid
        return UUID(uuid: u).uuidString
      }
      cursor = cursor.advanced(by: Int(cmd.cmdsize))
    }
    return nil
  }

  static func arch() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
  }

  static func signalName(_ s: Int32) -> String {
    switch s {
    case SIGABRT: return "SIGABRT"
    case SIGSEGV: return "SIGSEGV"
    case SIGBUS: return "SIGBUS"
    case SIGILL: return "SIGILL"
    case SIGFPE: return "SIGFPE"
    case SIGTRAP: return "SIGTRAP"
    default: return "SIG\(s)"
    }
  }
}
