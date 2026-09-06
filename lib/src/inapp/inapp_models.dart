/// Emitted when a user taps a button on an in-app message.
class NexusInAppAction {
  const NexusInAppAction({
    required this.messageId,
    required this.buttonId,
    required this.action,
    this.url,
    this.event,
  });

  final String messageId;
  final String buttonId;

  /// `dismiss` | `url` | `event`.
  final String action;
  final String? url;
  final String? event;
}

/// A button on an in-app message.
class NexusInAppButton {
  const NexusInAppButton({
    required this.id,
    required this.text,
    required this.action,
    this.url,
    this.event,
    this.style,
  });

  final String id;
  final String text;

  /// `dismiss` | `url` | `event`.
  final String action;
  final String? url;
  final String? event;

  /// `primary` | `secondary` | `text`.
  final String? style;

  factory NexusInAppButton.fromJson(Map<String, dynamic> j) => NexusInAppButton(
        id: (j['id'] ?? '').toString(),
        text: (j['text'] ?? '').toString(),
        action: (j['action'] ?? 'dismiss').toString(),
        url: j['url']?.toString(),
        event: j['event']?.toString(),
        style: j['style']?.toString(),
      );
}

/// An in-app message the SDK can display (modal / banner / center / fullscreen).
class NexusInAppMessage {
  const NexusInAppMessage({
    required this.id,
    required this.layout,
    this.title,
    this.body,
    this.imageUrl,
    this.backgroundColor,
    this.textColor,
    this.buttons = const [],
    this.triggerType,
    this.triggerEvent,
    this.maxDisplays,
    this.perSession = false,
  });

  final String id;

  /// `modal` | `banner_top` | `banner_bottom` | `center` | `fullscreen`.
  final String layout;
  final String? title;
  final String? body;
  final String? imageUrl;
  final String? backgroundColor;
  final String? textColor;
  final List<NexusInAppButton> buttons;

  /// `session_start` | `event` (null = show on fetch).
  final String? triggerType;
  final String? triggerEvent;
  final int? maxDisplays;
  final bool perSession;

  factory NexusInAppMessage.fromJson(Map<String, dynamic> j) {
    final content = (j['content'] as Map?)?.cast<String, dynamic>() ?? const {};
    final trigger = (j['trigger'] as Map?)?.cast<String, dynamic>();
    final buttons = (j['buttons'] as List?)
            ?.whereType<Map>()
            .map((b) => NexusInAppButton.fromJson(b.cast<String, dynamic>()))
            .toList() ??
        const <NexusInAppButton>[];
    return NexusInAppMessage(
      id: (j['id'] ?? '').toString(),
      layout: (j['layout'] ?? 'modal').toString(),
      title: content['title']?.toString(),
      body: content['body']?.toString(),
      imageUrl: content['imageUrl']?.toString(),
      backgroundColor: content['backgroundColor']?.toString(),
      textColor: content['textColor']?.toString(),
      buttons: buttons,
      triggerType: trigger?['type']?.toString(),
      triggerEvent: trigger?['event']?.toString(),
      maxDisplays: (j['maxDisplays'] as num?)?.toInt(),
      perSession: j['perSession'] == true,
    );
  }
}
