import Foundation
import UserNotifications

/**
 Missed-call notification — the iOS twin of Android's `NexusCallNotification`.

 CallKit already logs an unanswered call in the system Recents (that is what
 `reportCall(..., reason: .unanswered)` does), which is the real "missed call"
 entry. This adds the visible banner Android posts alongside it, so both
 platforms leave the same trace when a caller gives up.

 Deliberately does NOT prompt for notification permission: a missed call is not
 the moment to ask. If the host app has not been granted permission, the Recents
 entry still stands on its own.
 */
enum NexusCallNotification {

  private static let categoryId = "nexus_missed_call"

  /// Post a "Missed call" notification for [callId]. No-op when the app has no
  /// notification authorization.
  static func showMissed(callId: String, from: String, displayName: String?) {
    guard !callId.isEmpty else { return }
    let name = (displayName?.isEmpty == false)
      ? displayName!
      : (from.isEmpty ? "Unknown caller" : from)

    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus == .authorized
        || settings.authorizationStatus == .provisional
        || settings.authorizationStatus == .ephemeral else { return }

      let content = UNMutableNotificationContent()
      content.title = name
      content.body = "Missed call"
      content.categoryIdentifier = categoryId
      content.userInfo = [
        "type": "missed_call",
        "sessionId": callId,
        "from": from,
        "callerName": displayName as Any,
      ]
      if #available(iOS 15.0, *) {
        content.interruptionLevel = .timeSensitive
      }
      let request = UNNotificationRequest(identifier: identifier(callId), content: content, trigger: nil)
      center.add(request) { error in
        if let error = error {
          NSLog("[NexusVoice] missed-call notification failed: \(error.localizedDescription)")
        }
      }
    }
  }

  /// NOTE — there is deliberately no `cancel` counterpart to Android's.
  /// Android posts its OWN ring notification and must tear it down on every end
  /// path; iOS's ring is the CallKit screen, which the provider dismisses itself.
  /// A `cancel` here could only remove the missed-call banner — which the end
  /// paths run right after posting it, silently wiping it.
  ///
  /// The identifier is stable per call so a re-delivered cancel REPLACES the
  /// banner instead of stacking duplicates.
  private static func identifier(_ callId: String) -> String { "nexus.missed.\(callId)" }
}
