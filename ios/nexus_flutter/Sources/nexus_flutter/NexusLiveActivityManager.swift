import Foundation

#if os(iOS)
  import ActivityKit

  /// Manages the ActivityKit lifecycle for `NexusLiveActivityAttributes` (see
  /// LiveActivity/NexusLiveActivityAttributes.swift) and forwards tokens and
  /// diagnostics to Dart, which registers them with Nexus.
  ///
  /// Activities are looked up through ActivityKit itself (`Activity.activities`),
  /// not an in-memory map, so update/end keep working after an app restart and
  /// for activities the server started by push.
  @available(iOS 16.1, *)
  final class NexusLiveActivityManager {
    static let shared = NexusLiveActivityManager()
    typealias Attrs = NexusLiveActivityAttributes

    /// Called with `{ kind: pushToStart|update|status, … }`.
    var onToken: (([String: Any]) -> Void)?

    private var observing = false
    private var tracked = Set<String>() // Activity.id

    // MARK: Observe (push-to-start, push-started activities, diagnostics)

    /// Idempotent. Reports status on every call (cheap; useful after a Flutter
    /// hot restart), starts the observers once.
    func observe() {
      reportStatus("launch")
      guard !observing else { return }
      observing = true

      if #available(iOS 17.2, *) {
        Task {
          for await data in Activity<Attrs>.pushToStartTokenUpdates {
            self.emit(["kind": "pushToStart", "activityType": Attrs.typeName, "token": Self.hex(data)])
          }
        }
      }
      Task {
        for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
          self.emit(["kind": "status", "event": "enablement-changed", "enabled": enabled])
        }
      }
      // Already-running + newly started (incl. push-to-start) activities.
      Task {
        for activity in Activity<Attrs>.activities { self.track(activity) }
        for await activity in Activity<Attrs>.activityUpdates { self.track(activity) }
      }
    }

    private func track(_ activity: Activity<Attrs>) {
      guard tracked.insert(activity.id).inserted else { return }
      let logicalId = activity.attributes.activityId ?? activity.id
      emit(["kind": "status", "event": "activity", "activityId": logicalId, "state": String(describing: activity.activityState)])
      if let urls = activity.attributes.template?.imageURLs, !urls.isEmpty { NexusLiveActivityImageCache.cache(urls) }
      Task {
        for await data in activity.pushTokenUpdates {
          self.emit(["kind": "update", "activityId": logicalId, "activityType": activity.attributes.name, "token": Self.hex(data)])
        }
      }
      Task {
        for await state in activity.activityStateUpdates {
          self.emit(["kind": "status", "event": "activity-state", "activityId": logicalId, "state": String(describing: state)])
          if state == .ended || state == .dismissed { self.tracked.remove(activity.id) }
        }
      }
    }

    private func reportStatus(_ event: String) {
      let auth = ActivityAuthorizationInfo()
      var info: [String: Any] = [
        "kind": "status", "event": event,
        "enabled": auth.areActivitiesEnabled,
        "running": Activity<Attrs>.activities.map { "\($0.attributes.activityId ?? $0.id)=\(String(describing: $0.activityState))" },
        "appGroup": NexusLiveActivityImageCache.appGroup ?? "",
      ]
      if #available(iOS 16.2, *) { info["frequentPushes"] = auth.frequentPushesEnabled }
      emit(info)
    }

    // MARK: Local start / update / end

    func start(activityId: String, activityType: String, contentState: [String: Any]?, template: [String: Any]?) {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else {
        emit(["kind": "status", "event": "start-failed", "activityId": activityId, "error": "Live Activities are disabled for this app"])
        return
      }
      let tpl = NexusLiveActivityTemplate(map: template)
      if let urls = tpl?.imageURLs, !urls.isEmpty { NexusLiveActivityImageCache.cache(urls) }
      let attrs = Attrs(name: activityType.isEmpty ? Attrs.typeName : activityType, activityId: activityId, template: tpl)
      let state = Attrs.ContentState(map: contentState)
      do {
        let activity: Activity<Attrs>
        if #available(iOS 16.2, *) {
          activity = try Activity.request(attributes: attrs, content: ActivityContent(state: state, staleDate: nil), pushType: .token)
        } else {
          activity = try Activity.request(attributes: attrs, contentState: state, pushType: .token)
        }
        track(activity)
      } catch {
        emit(["kind": "status", "event": "start-failed", "activityId": activityId, "error": String(describing: error)])
      }
    }

    func update(activityId: String, contentState: [String: Any]?) {
      let state = Attrs.ContentState(map: contentState)
      for activity in find(activityId) {
        Task {
          if #available(iOS 16.2, *) { await activity.update(ActivityContent(state: state, staleDate: nil)) }
          else { await activity.update(using: state) }
        }
      }
    }

    func end(activityId: String, contentState: [String: Any]?) {
      let state = contentState.map { Attrs.ContentState(map: $0) }
      for activity in find(activityId) {
        Task {
          if #available(iOS 16.2, *) {
            await activity.end(state.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: .default)
          } else {
            await activity.end(using: state, dismissalPolicy: .default)
          }
        }
      }
    }

    func cacheImages(_ urls: [String]) { NexusLiveActivityImageCache.cache(urls) }

    // MARK: Helpers

    private func find(_ activityId: String) -> [Activity<Attrs>] {
      Activity<Attrs>.activities.filter { ($0.attributes.activityId ?? $0.id) == activityId || $0.id == activityId }
    }

    private func emit(_ info: [String: Any]) {
      DispatchQueue.main.async { self.onToken?(info) }
    }

    private static func hex(_ data: Data) -> String {
      data.map { String(format: "%02x", $0) }.joined()
    }
  }
#endif
