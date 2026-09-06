import UserNotifications

/// Nexus Notification Service Extension.
///
/// Add this as a **Notification Service Extension** target to your iOS app (see
/// the README, §16 “iOS action buttons & rich media”). iOS runs it just before a
/// notification is displayed — in every app state, including when the app is
/// killed — so it can turn `nexus_buttons` into real action buttons and attach
/// the `nexus_image` as rich media. No extension = plain alerts (title/body/
/// badge still work); with it, buttons + images render reliably.
final class NexusNotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    bestAttempt = content
    let userInfo = content.userInfo

    registerButtons(userInfo["nexus_buttons"]) { categoryId in
      if let categoryId = categoryId { content.categoryIdentifier = categoryId }
      // Attach rich media (image) if present, then finish.
      if let urlString = userInfo["nexus_image"] as? String, let url = URL(string: urlString) {
        self.attach(url) { attachment in
          if let attachment = attachment { content.attachments = [attachment] }
          contentHandler(content)
        }
      } else {
        contentHandler(content)
      }
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let handler = contentHandler, let content = bestAttempt { handler(content) }
  }

  /// Build a category from the button defs and register it (merged with any
  /// existing categories). Calls back with its identifier, or nil if no buttons.
  private func registerButtons(_ raw: Any?, completion: @escaping (String?) -> Void) {
    guard let items = parseButtons(raw), !items.isEmpty else { completion(nil); return }
    let actions = items.map { UNNotificationAction(identifier: $0.id, title: $0.text, options: [.foreground]) }
    let categoryId = "nexus_actions"
    let category = UNNotificationCategory(identifier: categoryId, actions: actions, intentIdentifiers: [], options: [])
    let center = UNUserNotificationCenter.current()
    center.getNotificationCategories { existing in
      var byId = Dictionary(existing.map { ($0.identifier, $0) }, uniquingKeysWith: { _, new in new })
      byId[categoryId] = category
      center.setNotificationCategories(Set(byId.values))
      completion(categoryId)
    }
  }

  private func parseButtons(_ raw: Any?) -> [(id: String, text: String)]? {
    guard let arr = raw as? [[String: Any]] else { return nil }
    return arr.compactMap { b in
      guard let id = b["id"] as? String, let text = b["text"] as? String else { return nil }
      return (id, text)
    }
  }

  private func attach(_ url: URL, completion: @escaping (UNNotificationAttachment?) -> Void) {
    URLSession.shared.downloadTask(with: url) { tmp, response, _ in
      guard let tmp = tmp else { completion(nil); return }
      let ext = (response?.suggestedFilename as NSString?)?.pathExtension ?? url.pathExtension
      let dest = tmp.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "." + (ext.isEmpty ? "img" : ext))
      do {
        try FileManager.default.moveItem(at: tmp, to: dest)
        completion(try UNNotificationAttachment(identifier: "nexus_image", url: dest, options: nil))
      } catch {
        completion(nil)
      }
    }.resume()
  }
}
