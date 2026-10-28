import NexusLiveActivityKit
import SwiftUI
import WidgetKit

// The whole Widget Extension for Nexus Live Activities (README §18). Every
// design comes from the Nexus dashboard / API — no app update for new ones.
// Images a template references by `asset` go in this extension's Assets.xcassets.
@main
struct AppWidgets: WidgetBundle {
  var body: some Widget {
    NexusLiveActivityWidget()
  }
}
