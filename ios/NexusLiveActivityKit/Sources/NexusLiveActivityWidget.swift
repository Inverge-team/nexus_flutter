import ActivityKit
import SwiftUI
import WidgetKit

/// The Nexus Live Activity widget — renders any template designed in the Nexus
/// dashboard (or sent via the API). Add it to your Widget Extension once:
///
///     import NexusLiveActivityKit
///     @main struct AppWidgets: WidgetBundle {
///       var body: some Widget { NexusLiveActivityWidget() }
///     }
///
/// New designs then need no app update.
@available(iOS 16.1, *)
public struct NexusLiveActivityWidget: Widget {
  public init() {}

  public var body: some WidgetConfiguration {
    ActivityConfiguration(for: NexusLiveActivityAttributes.self) { context in
      let m = NexusLAModel(attributes: context.attributes, state: context.state)
      NexusLALockScreen(m: m)
        .widgetURL(m.deepLink)
    } dynamicIsland: { context in
      let m = NexusLAModel(attributes: context.attributes, state: context.state)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 8) {
            NexusLABadge(m: m, size: 28)
            if let title = m.title {
              Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            }
          }
          .padding(.leading, 4)
          .environment(\.layoutDirection, m.direction)
        }
        DynamicIslandExpandedRegion(.trailing) {
          NexusLAEta(m: m, font: .system(size: 18, weight: .bold, design: .rounded), color: .white)
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            NexusLATrack(m: m, onDark: true)
            if let sub = m.subtitle {
              Text(sub).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
          }
          .padding(.horizontal, 4)
          .environment(\.layoutDirection, m.direction)
        }
      } compactLeading: {
        if let tracker = m.trackerImage, !m.isCanceled {
          tracker.resizable().aspectRatio(contentMode: .fit).frame(height: 12)
        } else {
          m.headlineIcon.font(.system(size: 13, weight: .bold)).foregroundStyle(m.accent)
        }
      } compactTrailing: {
        NexusLACompactTrailing(m: m)
      } minimal: {
        m.headlineIcon.foregroundStyle(m.accent)
      }
      .keylineTint(m.accent)
      .widgetURL(m.deepLink)
    }
  }
}

// MARK: - Lock Screen

@available(iOS 16.1, *)
struct NexusLALockScreen: View {
  let m: NexusLAModel
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let dark = scheme == .dark
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 10) {
        NexusLABadge(m: m)
        VStack(alignment: .leading, spacing: 2) {
          if let title = m.title {
            Text(title)
              .font(.headline)
              .foregroundStyle(m.isCanceled ? m.danger : m.textColor(dark))
              .lineLimit(1)
          }
          if let sub = m.subtitle {
            Text(sub).font(.caption).foregroundStyle(m.textColor(dark).opacity(0.7)).lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        if m.hasEta {
          VStack(alignment: .trailing, spacing: 0) {
            NexusLAEta(m: m, color: m.textColor(dark))
            if let label = m.etaLabel {
              Text(label).font(.caption2.weight(.semibold)).foregroundStyle(m.accent)
            }
          }
        }
      }

      if m.layout != .text { NexusLATrack(m: m, onDark: dark) }

      if let body = m.bodyText {
        Text(body).font(.caption).foregroundStyle(m.textColor(dark).opacity(0.7)).lineLimit(2)
      }
    }
    .padding(16)
    .environment(\.layoutDirection, m.direction)
    .activityBackgroundTint(m.background(dark))
    .activitySystemActionForegroundColor(m.textColor(dark))
  }
}

// MARK: - Building blocks

@available(iOS 16.1, *)
struct NexusLABadge: View {
  let m: NexusLAModel
  var size: CGFloat = 36
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        .fill(m.isCanceled ? m.danger : m.isDone ? m.accent : m.brand)
      m.headlineIcon
        .font(.system(size: size * 0.42, weight: .bold))
        .foregroundStyle(Color.white)
        .frame(width: size * 0.6, height: size * 0.6)
    }
    .frame(width: size, height: size)
  }
}

@available(iOS 16.1, *)
struct NexusLAEta: View {
  let m: NexusLAModel
  var font: Font = .system(size: 22, weight: .bold, design: .rounded)
  var color: Color = .primary
  var body: some View {
    if let date = m.etaDate {
      Text(timerInterval: Date()...date, countsDown: true)
        .font(font).monospacedDigit().foregroundStyle(color)
        .multilineTextAlignment(.trailing)
    } else if let eta = m.etaText {
      Text(eta).font(font).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
    }
  }
}

@available(iOS 16.1, *)
struct NexusLACompactTrailing: View {
  let m: NexusLAModel
  var body: some View {
    if let date = m.etaDate {
      Text(timerInterval: Date()...date, countsDown: true)
        .monospacedDigit().font(.caption.weight(.semibold)).foregroundStyle(m.accent)
        .frame(maxWidth: 44)
    } else if let eta = m.etaText {
      Text(eta).font(.caption.weight(.semibold)).foregroundStyle(m.accent).lineLimit(1).frame(maxWidth: 52)
    } else {
      ZStack {
        Circle().stroke(Color.white.opacity(0.2), lineWidth: 3)
        Circle()
          .trim(from: 0, to: m.isCanceled ? 1 : m.overallProgress)
          .stroke(m.isCanceled ? m.danger : m.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
          .rotationEffect(.degrees(-90))
        m.headlineIcon.font(.system(size: 8, weight: .bold)).foregroundStyle(m.isCanceled ? m.danger : m.accent)
      }
      .frame(width: 20, height: 20)
    }
  }
}

/// Steps (nodes + labels) or a progress bar, with the tracker riding above.
/// Coordinates are explicit (mirrored for RTL) so the tracker and nodes always
/// agree regardless of the system layout direction.
@available(iOS 16.1, *)
struct NexusLATrack: View {
  let m: NexusLAModel
  var onDark = false

  private let trackerSize: CGFloat = 20
  private let node: CGFloat = 20
  private let current: CGFloat = 26
  private let endIcon: CGFloat = 22

  private var hasTracker: Bool { m.trackerImage != nil && !m.isCanceled }
  private var lane: CGFloat { hasTracker ? trackerSize + 8 : 0 }
  private var isSteps: Bool { m.layout == .steps && m.steps.count >= 2 }

  var body: some View {
    GeometryReader { geo in
      let w = max(geo.size.width, 1)
      let mid = lane + (isSteps ? current : endIcon) / 2
      ZStack(alignment: .topLeading) {
        if isSteps { steps(w: w, lineY: mid) } else { bar(w: w, lineY: mid) }
        if hasTracker, let img = m.trackerImage {
          let tw = trackerSize * m.trackerAspect
          img.resizable().aspectRatio(contentMode: .fit).frame(height: trackerSize)
            .shadow(color: onDark ? Color.white.opacity(0.3) : Color.black.opacity(0.2), radius: 2, y: 1)
            .position(x: min(max(trackerX(w: w), tw / 2), w - tw / 2), y: trackerSize / 2 + 2)
        }
      }
    }
    .frame(height: lane + (isSteps ? current + 18 : endIcon + 2))
  }

  // x for a fraction 0…1 along the usable track, mirrored for RTL.
  private func x(_ f: Double, w: CGFloat, inset: CGFloat) -> CGFloat {
    let v = inset + (w - inset * 2) * CGFloat(min(1, max(0, f)))
    return m.isRTL ? w - v : v
  }

  private func trackerX(w: CGFloat) -> CGFloat {
    if isSteps {
      let n = m.steps.count
      let col = w / CGFloat(n)
      let v = (CGFloat(m.trackerSlot) + 0.5) * col
      return m.isRTL ? w - v : v
    }
    return x(m.barProgress, w: w, inset: endIcon)
  }

  private var baseLine: Color { onDark ? Color.white.opacity(0.18) : m.brand.opacity(0.14) }

  @ViewBuilder
  private func steps(w: CGFloat, lineY: CGFloat) -> some View {
    let n = m.steps.count
    let col = w / CGFloat(n)
    let cx: (Double) -> CGFloat = { i in
      let v = (CGFloat(i) + 0.5) * col
      return m.isRTL ? w - v : v
    }
    Path { p in
      p.move(to: CGPoint(x: cx(0), y: lineY)); p.addLine(to: CGPoint(x: cx(Double(n - 1)), y: lineY))
    }
    .stroke(baseLine, style: StrokeStyle(lineWidth: 4, lineCap: .round))
    if !m.isCanceled {
      Path { p in
        p.move(to: CGPoint(x: cx(0), y: lineY)); p.addLine(to: CGPoint(x: cx(m.trackerSlot), y: lineY))
      }
      .stroke(m.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
    }
    ForEach(Array(m.steps.enumerated()), id: \.offset) { i, s in
      let isCurrent = i == m.stepIndex && !m.isCanceled && !m.isDone
      let isDone = !m.isCanceled && (i < m.stepIndex || m.isDone)
      nodeView(m.image(s.icon) ?? Image(systemName: "circle.fill"), isCurrent: isCurrent, isDone: isDone)
        .position(x: cx(Double(i)), y: lineY)
      Text(s.label ?? "")
        .font(.system(size: 10, weight: isCurrent ? .bold : .medium))
        .foregroundStyle(labelColor(isCurrent: isCurrent, isDone: isDone))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: max(col - 2, 1))
        .position(x: cx(Double(i)), y: lineY + current / 2 + 9)
    }
  }

  @ViewBuilder
  private func bar(w: CGFloat, lineY: CGFloat) -> some View {
    let start = x(0, w: w, inset: endIcon)
    let end = x(1, w: w, inset: endIcon)
    let at = x(m.barProgress, w: w, inset: endIcon)
    Path { p in p.move(to: CGPoint(x: start, y: lineY)); p.addLine(to: CGPoint(x: end, y: lineY)) }
      .stroke(baseLine, style: StrokeStyle(lineWidth: 5, lineCap: .round))
    if !m.isCanceled {
      Path { p in p.move(to: CGPoint(x: start, y: lineY)); p.addLine(to: CGPoint(x: at, y: lineY)) }
        .stroke(m.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
    }
    if let icon = m.image(m.template?.startIcon) {
      endPin(icon, filled: true).position(x: start, y: lineY)
    }
    if let icon = m.image(m.template?.endIcon) {
      endPin(icon, filled: m.isDone).position(x: end, y: lineY)
    }
  }

  private func endPin(_ icon: Image, filled: Bool) -> some View {
    ZStack {
      Circle().fill(filled ? m.accent : (onDark ? Color.white.opacity(0.16) : Color.white))
      Circle().strokeBorder(filled ? Color.clear : m.accent, lineWidth: 1.5)
      icon.resizable().aspectRatio(contentMode: .fit).frame(width: 11, height: 11)
        .foregroundStyle(filled ? Color.white : m.accent)
    }
    .frame(width: endIcon, height: endIcon)
  }

  private func labelColor(isCurrent: Bool, isDone: Bool) -> Color {
    let muted = (onDark ? Color.white : m.brand).opacity(0.45)
    if m.isCanceled { return muted }
    if isCurrent { return onDark ? .white : m.brand }
    if isDone { return m.accent }
    return muted
  }

  @ViewBuilder
  private func nodeView(_ icon: Image, isCurrent: Bool, isDone: Bool) -> some View {
    if isCurrent {
      ZStack {
        Circle().fill(m.brand)
        Circle().strokeBorder(m.accent, lineWidth: 2.5)
        icon.resizable().aspectRatio(contentMode: .fit).frame(width: 12, height: 12).foregroundStyle(Color.white)
      }
      .frame(width: current, height: current)
    } else if isDone {
      ZStack {
        Circle().fill(m.accent)
        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.white)
      }
      .frame(width: node, height: node)
    } else {
      ZStack {
        Circle().fill(onDark ? Color.black.opacity(0.25) : Color.white)
        Circle().strokeBorder(onDark ? Color.white.opacity(0.25) : m.brand.opacity(0.3), lineWidth: 2)
      }
      .frame(width: node, height: node)
    }
  }
}
