import ActivityKit
import SwiftUI
import UIKit

/// Everything a presentation needs, derived once from template + content state.
@available(iOS 16.1, *)
struct NexusLAModel {
  enum Layout { case steps, progress, text }

  let template: NexusLiveActivityTemplate?
  let state: NexusLiveActivityAttributes.ContentState
  let steps: [NexusLiveActivityTemplate.Step]
  let layout: Layout
  let stepIndex: Int
  let isCanceled: Bool
  let isDone: Bool

  init(attributes: NexusLiveActivityAttributes, state: NexusLiveActivityAttributes.ContentState) {
    template = attributes.template
    self.state = state
    steps = attributes.template?.steps ?? []
    switch attributes.template?.layout?.lowercased() {
    case "steps": layout = steps.count >= 2 ? .steps : .progress
    case "text": layout = .text
    case "progress": layout = .progress
    default: layout = steps.count >= 2 ? .steps : (state.progress != nil || attributes.template != nil ? .progress : .text)
    }

    let st = Self.norm(state.state ?? "")
    isCanceled = st.hasPrefix("cancel")
    let wanted = Self.norm(state.step ?? "")
    let found = wanted.isEmpty ? nil : steps.firstIndex { Self.norm($0.id) == wanted || Self.norm($0.label ?? "") == wanted }
    let idx = found ?? (st == "done" || st == "completed" ? max(steps.count - 1, 0) : 0)
    stepIndex = idx
    let p = Self.fraction(state.progress)
    isDone = !isCanceled && (st == "done" || st == "completed"
      || (layout == .steps && idx == steps.count - 1)
      || (layout == .progress && (p ?? 0) >= 1))
  }

  // MARK: Steps / progress

  var currentStep: NexusLiveActivityTemplate.Step? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }

  /// Tracker position in step units: the current step + progress toward the next.
  var trackerSlot: Double {
    let last = Double(max(steps.count - 1, 0))
    if isDone { return last }
    let p = Self.fraction(state.progress) ?? 0
    return min(last, Double(stepIndex) + (stepIndex < steps.count - 1 ? p : 0))
  }

  var barProgress: Double { isDone ? 1 : Self.fraction(state.progress) ?? 0 }

  var overallProgress: Double {
    if layout == .steps, !steps.isEmpty { return isDone ? 1 : Double(stepIndex + 1) / Double(steps.count) }
    return barProgress
  }

  // MARK: Texts

  var title: String? {
    if let t = state.title { return t }
    if isCanceled { return resolve(template?.canceled?.title) ?? "Canceled" }
    return resolve(currentStep?.title) ?? resolve(template?.title) ?? state.status
  }
  var subtitle: String? { state.subtitle ?? resolve(currentStep?.subtitle) ?? resolve(template?.subtitle) }
  var bodyText: String? {
    if let b = state.body { return b }
    if isCanceled, let b = resolve(template?.canceled?.body) { return b }
    return resolve(currentStep?.body) ?? resolve(template?.body)
  }

  /// `{{key}}` → value (plus built-ins `{{step}}`, `{{eta}}`); unresolved
  /// placeholders vanish and dangling separators are tidied away.
  func resolve(_ text: String?) -> String? {
    guard var s = text, !s.isEmpty else { return nil }
    var vals = state.values ?? [:]
    if vals["step"] == nil, let label = currentStep?.label { vals["step"] = label }
    if let re = try? NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_.-]+)\\s*\\}\\}") {
      let ns = s as NSString
      var out = ""
      var last = 0
      for match in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
        out += vals[ns.substring(with: match.range(at: 1))] ?? ""
        last = match.range.location + match.range.length
      }
      out += ns.substring(from: last)
      s = out
    }
    let seps = CharacterSet(charactersIn: "·•|,-–— ").union(.whitespaces)
    // collapse "a ·  · b" → "a · b"
    while let r = s.range(of: "·\\s*·", options: .regularExpression) { s.replaceSubrange(r, with: "·") }
    s = s.trimmingCharacters(in: seps)
    return s.isEmpty ? nil : s
  }

  // MARK: ETA

  private var etaAllowed: Bool {
    // showEta=false is a master switch; otherwise a step's own setting decides (default on).
    if isCanceled || isDone || template?.showEta == false { return false }
    return currentStep?.eta ?? true
  }
  /// Future arrival time for a live countdown (`Text(timerInterval:)` needs a valid range).
  var etaDate: Date? {
    guard etaAllowed, let t = state.etaAt else { return nil }
    let d = Date(timeIntervalSince1970: t)
    return d > Date() ? d : nil
  }
  var etaText: String? { etaAllowed ? state.values?["eta"] : nil }
  var hasEta: Bool { etaDate != nil || etaText != nil }
  var etaLabel: String? { template?.etaLabel }

  // MARK: Direction, theme, images

  var isRTL: Bool { template?.dir?.lowercased() == "rtl" }
  var direction: LayoutDirection { isRTL ? .rightToLeft : .leftToRight }

  private var theme: NexusLiveActivityTemplate.Theme? { template?.theme }
  var brand: Color { Color(nexusHex: theme?.brand) ?? Color(red: 0.31, green: 0.27, blue: 0.9) }
  var accent: Color { Color(nexusHex: theme?.accent) ?? Color(red: 0.06, green: 0.73, blue: 0.51) }
  var danger: Color { Color(nexusHex: theme?.danger) ?? Color(red: 0.94, green: 0.27, blue: 0.27) }
  func background(_ dark: Bool) -> Color {
    (dark ? Color(nexusHex: theme?.bgDark) : Color(nexusHex: theme?.bg))
      ?? (dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.96, green: 0.96, blue: 0.97))
  }
  func textColor(_ dark: Bool) -> Color {
    (dark ? Color(nexusHex: theme?.textDark) : Color(nexusHex: theme?.text)) ?? (dark ? .white : Color(red: 0.07, green: 0.09, blue: 0.15))
  }

  var headlineIcon: Image {
    if isCanceled { return image(template?.canceled?.icon) ?? Image(systemName: "xmark") }
    if isDone, layout == .steps { return Image(systemName: "checkmark") }
    return image(currentStep?.icon) ?? image(template?.icon) ?? Image(systemName: "bell.fill")
  }

  private var trackerRef: NexusLiveActivityTemplate.ImageRef? {
    isRTL ? (template?.trackerRtl ?? template?.tracker) : template?.tracker
  }
  var trackerImage: Image? { image(trackerRef) }
  var trackerAspect: CGFloat {
    if let a = template?.trackerAspect, a > 0 { return CGFloat(a) }
    if let ui = uiImage(trackerRef), ui.size.height > 0 { return ui.size.width / ui.size.height }
    return 1
  }

  var deepLink: URL? { resolve(template?.url).flatMap(URL.init(string:)) }

  /// Cached remote image (App Group) → bundled asset → SF Symbol.
  func image(_ ref: NexusLiveActivityTemplate.ImageRef?) -> Image? {
    guard let ref = ref else { return nil }
    if let ui = cachedOrAsset(ref) { return Image(uiImage: ui) }
    if let sf = ref.sf, UIImage(systemName: sf) != nil { return Image(systemName: sf) }
    return nil
  }

  private func uiImage(_ ref: NexusLiveActivityTemplate.ImageRef?) -> UIImage? {
    guard let ref = ref else { return nil }
    return cachedOrAsset(ref)
  }

  private func cachedOrAsset(_ ref: NexusLiveActivityTemplate.ImageRef) -> UIImage? {
    if let url = ref.url, let ui = NexusLiveActivityImageCache.load(url) { return ui }
    if let asset = ref.asset, let ui = UIImage(named: asset) { return ui }
    return nil
  }

  // MARK: Helpers

  static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
  static func fraction(_ p: Double?) -> Double? {
    guard let p = p else { return nil }
    return min(1, max(0, p > 1 ? p / 100 : p))
  }
}

extension Color {
  /// "#RRGGBB" / "RRGGBB" / "#RRGGBBAA"; nil when absent or malformed.
  init?(nexusHex: String?) {
    guard var s = nexusHex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
    let r, g, b, a: Double
    if s.count == 6 {
      r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255; a = 1
    } else {
      r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255; b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
    }
    self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
  }
}
