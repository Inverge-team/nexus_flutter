import Foundation

#if os(iOS)
  import ActivityKit

  /// Turn-key default Live Activity attributes. Your Widget Extension renders
  /// this `ContentState`; the SDK maps the server/app content-state onto these
  /// fields. For custom fields, define your own `ActivityAttributes` and drive it
  /// yourself, registering tokens via `nexus.liveActivity`.
  @available(iOS 16.1, *)
  public struct NexusLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
      public var title: String?
      public var subtitle: String?
      public var body: String?
      public var status: String?
      public var progress: Double? // 0.0 ... 1.0
      public init(title: String? = nil, subtitle: String? = nil, body: String? = nil, status: String? = nil, progress: Double? = nil) {
        self.title = title; self.subtitle = subtitle; self.body = body; self.status = status; self.progress = progress
      }
    }

    public var name: String // the activityType
    public init(name: String) { self.name = name }
  }

  /// Manages the ActivityKit lifecycle for the default attributes and forwards
  /// push-to-start + update tokens back to Dart.
  @available(iOS 16.1, *)
  final class NexusLiveActivityManager {
    static let shared = NexusLiveActivityManager()

    /// Called with `{ kind, activityType?, activityId?, token }`.
    var onToken: (([String: Any]) -> Void)?

    private var activities: [String: Activity<NexusLiveActivityAttributes>] = [:]

    private func makeState(_ map: [String: Any]?) -> NexusLiveActivityAttributes.ContentState {
      let m = map ?? [:]
      let progress = (m["progress"] as? NSNumber).map { $0.doubleValue / 100.0 }
      return .init(
        title: m["title"] as? String,
        subtitle: m["subtitle"] as? String,
        body: (m["body"] as? String) ?? (m["status"] as? String),
        status: m["status"] as? String,
        progress: progress
      )
    }

    func start(activityId: String, activityType: String, contentState: [String: Any]?, attributes: [String: Any]?) {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      let attrs = NexusLiveActivityAttributes(name: activityType)
      let state = makeState(contentState)
      do {
        let activity: Activity<NexusLiveActivityAttributes>
        if #available(iOS 16.2, *) {
          activity = try Activity.request(
            attributes: attrs,
            content: ActivityContent(state: state, staleDate: nil),
            pushType: .token
          )
        } else {
          activity = try Activity.request(attributes: attrs, contentState: state, pushType: .token)
        }
        activities[activityId] = activity
        observeUpdateToken(activityId: activityId, activityType: activityType, activity: activity)
      } catch {
        NSLog("[Nexus] live activity start failed: \(error)")
      }
    }

    func update(activityId: String, contentState: [String: Any]?) {
      guard let activity = activities[activityId] else { return }
      let state = makeState(contentState)
      Task {
        if #available(iOS 16.2, *) {
          await activity.update(ActivityContent(state: state, staleDate: nil))
        } else {
          await activity.update(using: state)
        }
      }
    }

    func end(activityId: String, contentState: [String: Any]?) {
      guard let activity = activities[activityId] else { return }
      let state = makeState(contentState)
      Task {
        if #available(iOS 16.2, *) {
          await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
        } else {
          await activity.end(using: state, dismissalPolicy: .default)
        }
        activities[activityId] = nil
      }
    }

    /// Observe push-to-start tokens (iOS 17.2+) so the server can start activities.
    func observePushToStart(activityType: String) {
      if #available(iOS 17.2, *) {
        Task {
          for await tokenData in Activity<NexusLiveActivityAttributes>.pushToStartTokenUpdates {
            self.onToken?(["kind": "pushToStart", "activityType": activityType, "token": Self.hex(tokenData)])
          }
        }
      }
    }

    private func observeUpdateToken(activityId: String, activityType: String, activity: Activity<NexusLiveActivityAttributes>) {
      Task {
        for await tokenData in activity.pushTokenUpdates {
          self.onToken?(["kind": "update", "activityId": activityId, "activityType": activityType, "token": Self.hex(tokenData)])
        }
      }
    }

    private static func hex(_ data: Data) -> String {
      data.map { String(format: "%02x", $0) }.joined()
    }
  }
#endif
