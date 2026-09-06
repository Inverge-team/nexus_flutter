import ActivityKit
import SwiftUI
import WidgetKit

// The Widget Extension that renders the turn-key Live Activity. Add this as a
// Widget Extension target (see the README, §18 "Live Activities"). It uses the
// SDK's `NexusLiveActivityAttributes`, so import the Nexus SDK in the extension
// target (or share the attributes source with both targets). Customize the views
// freely — the SDK maps the server/app content-state onto these fields.
//
//   ContentState: title, subtitle, body, status, progress (0.0...1.0)

@available(iOS 16.1, *)
struct NexusLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: NexusLiveActivityAttributes.self) { context in
      // Lock Screen / banner presentation.
      VStack(alignment: .leading, spacing: 6) {
        if let title = context.state.title { Text(title).font(.headline) }
        if let body = context.state.body { Text(body).font(.subheadline).foregroundStyle(.secondary) }
        if let progress = context.state.progress {
          ProgressView(value: progress).tint(.accentColor)
        }
      }
      .padding()
      .activityBackgroundTint(Color(.systemBackground))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(context.state.title ?? "").font(.headline).lineLimit(1)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.status ?? "").font(.headline)
        }
        DynamicIslandExpandedRegion(.bottom) {
          if let progress = context.state.progress { ProgressView(value: progress) }
          if let body = context.state.body { Text(body).font(.caption) }
        }
      } compactLeading: {
        Text(context.state.title ?? "").lineLimit(1)
      } compactTrailing: {
        Text(context.state.status ?? "")
      } minimal: {
        Text(context.state.status ?? "•")
      }
    }
  }
}

@available(iOS 16.1, *)
struct NexusLiveActivityWidgetBundle: WidgetBundle {
  var body: some Widget { NexusLiveActivityWidget() }
}
