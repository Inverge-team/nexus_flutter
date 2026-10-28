import Foundation

#if os(iOS)
  import ActivityKit

  // ONE source file, compiled into BOTH the app (nexus_flutter pod) and the
  // Widget Extension (NexusLiveActivityKit pod) — ActivityKit matches the two by
  // type name, so they can never drift. Pure data: no Flutter, no UIKit.
  //
  // Decoding is deliberately lenient: iOS silently DROPS a push-to-start whose
  // attributes / content-state fail to decode, so a wrong type or an unknown
  // field must degrade a single field — never the whole Live Activity.

  /// Nexus Live Activity attributes. `template` (fixed for the activity's life)
  /// carries the design; `ContentState` carries only data, so updates stay small.
  @available(iOS 16.1, *)
  public struct NexusLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
      // Template-driven
      /// Current step id (steps layout), e.g. "on_the_way".
      public var step: String?
      /// active | canceled | done
      public var state: String?
      /// 0…1 (or 0…100). Steps layout: position between the current and next step.
      public var progress: Double?
      /// Arrival time (unix seconds) → live countdown, no pushes needed.
      public var etaAt: Double?
      /// Values for `{{placeholders}}` in the template's texts.
      public var values: [String: String]?
      // Plain (no template) — also overrides the template's texts when set.
      public var title: String?
      public var subtitle: String?
      public var body: String?
      public var status: String?

      public init(
        step: String? = nil, state: String? = nil, progress: Double? = nil, etaAt: Double? = nil,
        values: [String: String]? = nil, title: String? = nil, subtitle: String? = nil,
        body: String? = nil, status: String? = nil
      ) {
        self.step = step; self.state = state; self.progress = progress; self.etaAt = etaAt
        self.values = values; self.title = title; self.subtitle = subtitle; self.body = body; self.status = status
      }

      enum CodingKeys: String, CodingKey { case step, state, progress, etaAt, values, title, subtitle, body, status }

      public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        step = c.lenientString(.step)
        state = c.lenientString(.state)
        progress = c.lenientDouble(.progress)
        etaAt = c.lenientDouble(.etaAt)
        values = c.lenientStringMap(.values)
        title = c.lenientString(.title)
        subtitle = c.lenientString(.subtitle)
        body = c.lenientString(.body)
        status = c.lenientString(.status)
      }

      /// From a JSON-ish map (method channel / local start).
      public init(map: [String: Any]?) {
        let data = (try? JSONSerialization.data(withJSONObject: map ?? [:])) ?? Data("{}".utf8)
        self = (try? JSONDecoder().decode(ContentState.self, from: data)) ?? ContentState()
      }
    }

    /// Activity type (kept for backward compatibility with the plain widget).
    public var name: String
    /// Logical id the server uses to address this activity (e.g. "order_42").
    public var activityId: String?
    /// The design, from the Nexus dashboard / API.
    public var template: NexusLiveActivityTemplate?

    public init(name: String, activityId: String? = nil, template: NexusLiveActivityTemplate? = nil) {
      self.name = name; self.activityId = activityId; self.template = template
    }

    enum CodingKeys: String, CodingKey { case name, activityId, template }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      name = c.lenientString(.name) ?? NexusLiveActivityAttributes.typeName
      activityId = c.lenientString(.activityId)
      template = (try? c.decodeIfPresent(NexusLiveActivityTemplate.self, forKey: .template)) ?? nil
    }

    /// The `attributes-type` APNs push-to-start must name.
    public static let typeName = "NexusLiveActivityAttributes"
  }
#endif

// MARK: - Template (pure data — also usable off iOS 16.1)

/// A Live Activity design: layout, theme, texts with `{{placeholders}}`, images.
/// Every field is optional; the renderer has sensible defaults.
public struct NexusLiveActivityTemplate: Codable, Hashable {
  public var v: Int?
  /// steps | progress | text
  public var layout: String?
  /// ltr | rtl
  public var dir: String?
  public var theme: Theme?
  /// Header badge icon.
  public var icon: ImageRef?
  /// The moving icon on the track (e.g. a delivery truck), and an optional
  /// RTL variant (so artwork with lettering can face the travel direction).
  public var tracker: ImageRef?
  public var trackerRtl: ImageRef?
  /// Tracker width ÷ height (default 1).
  public var trackerAspect: Double?
  public var title: String?
  public var subtitle: String?
  public var body: String?
  public var steps: [Step]?
  public var canceled: Terminal?
  /// Progress layout: icons at the start / end of the bar.
  public var startIcon: ImageRef?
  public var endIcon: ImageRef?
  public var etaLabel: String?
  /// Show the ETA (default true; per step via `Step.eta`).
  public var showEta: Bool?
  /// Deep link opened when the activity is tapped.
  public var url: String?

  public struct Theme: Codable, Hashable {
    public var bg: String?
    public var bgDark: String?
    public var text: String?
    public var textDark: String?
    /// Badge / current-step colour.
    public var brand: String?
    /// Progress / done colour.
    public var accent: String?
    public var danger: String?
  }

  public struct Step: Codable, Hashable {
    public var id: String
    public var label: String?
    public var icon: ImageRef?
    /// Headline / sub line / body while this step is current (override the template's).
    public var title: String?
    public var subtitle: String?
    public var body: String?
    /// Show the ETA during this step (default: steps before the last third).
    public var eta: Bool?

    enum CodingKeys: String, CodingKey { case id, label, icon, title, subtitle, body, eta }
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = c.lenientString(.id) ?? ""
      label = c.lenientString(.label)
      icon = (try? c.decodeIfPresent(ImageRef.self, forKey: .icon)) ?? nil
      title = c.lenientString(.title)
      subtitle = c.lenientString(.subtitle)
      body = c.lenientString(.body)
      eta = (try? c.decodeIfPresent(Bool.self, forKey: .eta)) ?? nil
    }
  }

  public struct Terminal: Codable, Hashable {
    public var title: String?
    public var label: String?
    public var body: String?
    public var icon: ImageRef?
  }

  /// Image source, resolved in order: cached `url` (App Group) → bundled `asset`
  /// → SF Symbol `sf`. (`res` is the Android drawable name.)
  public struct ImageRef: Codable, Hashable {
    public var sf: String?
    public var asset: String?
    public var url: String?
    public var res: String?
  }

  enum CodingKeys: String, CodingKey {
    case v, layout, dir, theme, icon, tracker, trackerRtl, trackerAspect, title, subtitle, body, steps, canceled
    case startIcon, endIcon, etaLabel, showEta, url
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func opt<T: Decodable>(_ k: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil }
    v = opt(.v)
    layout = c.lenientString(.layout)
    dir = c.lenientString(.dir)
    theme = opt(.theme)
    icon = opt(.icon)
    tracker = opt(.tracker)
    trackerRtl = opt(.trackerRtl)
    trackerAspect = c.lenientDouble(.trackerAspect)
    title = c.lenientString(.title)
    subtitle = c.lenientString(.subtitle)
    body = c.lenientString(.body)
    // A malformed step drops the step, not the list.
    steps = ((try? c.decodeIfPresent([Lossy<Step>].self, forKey: .steps)) ?? nil)?.compactMap { $0.value }.filter { !$0.id.isEmpty }
    canceled = opt(.canceled)
    startIcon = opt(.startIcon)
    endIcon = opt(.endIcon)
    etaLabel = c.lenientString(.etaLabel)
    showEta = opt(.showEta)
    url = c.lenientString(.url)
  }

  /// From a JSON-ish map (method channel / local start).
  public init?(map: [String: Any]?) {
    guard let map = map, let data = try? JSONSerialization.data(withJSONObject: map),
          let t = try? JSONDecoder().decode(NexusLiveActivityTemplate.self, from: data) else { return nil }
    self = t
  }

  /// Every remote image URL the template references (for App Group caching).
  public var imageURLs: [String] {
    var refs: [ImageRef?] = [icon, tracker, trackerRtl, startIcon, endIcon, canceled?.icon]
    refs += (steps ?? []).map { $0.icon }
    return refs.compactMap { $0?.url }.filter { !$0.isEmpty }
  }
}

// MARK: - Lenient decoding helpers

private struct Lossy<T: Decodable>: Decodable {
  let value: T?
  init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
  /// String, or a number/bool rendered as text; nil when absent or unusable.
  func lenientString(_ key: Key) -> String? {
    if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
    if let d = try? decodeIfPresent(Double.self, forKey: key) {
      return d.rounded() == d && abs(d) < 1e15 ? String(Int64(d)) : String(d)
    }
    if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? "true" : "false" }
    return nil
  }

  /// Number, or a numeric string.
  func lenientDouble(_ key: Key) -> Double? {
    if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
    if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
    return nil
  }

  /// `{ "k": "v" }` where values may also be numbers / bools.
  func lenientStringMap(_ key: Key) -> [String: String]? {
    if let m = try? decodeIfPresent([String: String].self, forKey: key) { return m }
    guard let m = try? decodeIfPresent([String: LossyText].self, forKey: key) else { return nil }
    return m.compactMapValues { $0.text }
  }
}

private struct LossyText: Decodable {
  let text: String?
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let s = try? c.decode(String.self) { text = s }
    else if let d = try? c.decode(Double.self) { text = d.rounded() == d && abs(d) < 1e15 ? String(Int64(d)) : String(d) }
    else if let b = try? c.decode(Bool.self) { text = b ? "true" : "false" }
    else { text = nil }
  }
}

// MARK: - App Group image cache (app writes, widget reads)

#if os(iOS)
  import CryptoKit
  import UIKit

  /// Widgets can't download, so the app caches template images into a shared
  /// App Group container and the widget reads them from there. Opt-in: set the
  /// same `NexusAppGroup` Info.plist key (e.g. `group.com.company.app`) in the
  /// app AND the Widget Extension, with that App Group enabled on both targets.
  public enum NexusLiveActivityImageCache {
    /// Longest side, in pixels — Live Activity images must stay small.
    static let maxPixels: CGFloat = 240

    public static var appGroup: String? {
      (Bundle.main.object(forInfoDictionaryKey: "NexusAppGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var directory: URL? {
      guard let group = appGroup,
            let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
      return base.appendingPathComponent("NexusLiveActivity", isDirectory: true)
    }

    static func fileURL(for url: String) -> URL? {
      let name = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
      return directory?.appendingPathComponent(name + ".png")
    }

    public static func load(_ url: String) -> UIImage? {
      guard let file = fileURL(for: url) else { return nil }
      return UIImage(contentsOfFile: file.path)
    }

    /// Download (if not cached yet), downscale and store. App side only.
    public static func cache(_ urls: [String], completion: (() -> Void)? = nil) {
      guard let dir = directory else { completion?(); return }
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let group = DispatchGroup()
      for raw in Set(urls) {
        guard let file = fileURL(for: raw), !FileManager.default.fileExists(atPath: file.path),
              let url = URL(string: raw), url.scheme == "https" else { continue }
        group.enter()
        URLSession.shared.dataTask(with: url) { data, _, _ in
          defer { group.leave() }
          guard let data = data, let img = UIImage(data: data) else { return }
          let scale = min(1, maxPixels / max(img.size.width * img.scale, img.size.height * img.scale))
          let size = CGSize(width: img.size.width * img.scale * scale, height: img.size.height * img.scale * scale)
          let format = UIGraphicsImageRendererFormat.default()
          format.scale = 1
          let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
          try? small.pngData()?.write(to: file, options: .atomic)
        }.resume()
      }
      group.notify(queue: .main) { completion?() }
    }
  }
#endif
