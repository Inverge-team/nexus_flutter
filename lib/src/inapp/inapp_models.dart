import 'inapp_design.dart';

/// Emitted when a user taps a button on an in-app message.
class NexusInAppAction {
  const NexusInAppAction({
    required this.messageId,
    required this.buttonId,
    required this.action,
    this.url,
    this.event,
    this.value,
    this.variantId,
  });

  final String messageId;

  /// The A/B variant the tap happened in, if any.
  final String? variantId;
  final String buttonId;

  /// `dismiss` | `url` | `event` | `copy`.
  final String action;
  final String? url;
  final String? event;

  /// For `copy`: the text that was put on the clipboard.
  final String? value;
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
    this.value,
  });

  final String id;
  final String text;

  /// `dismiss` | `url` | `event` | `copy` (designed messages only).
  final String action;
  final String? url;
  final String? event;

  /// For `copy`: the text to put on the clipboard.
  final String? value;

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
    this.design,
    this.variantId,
    this.isTest = false,
  });

  final String id;

  /// `modal` | `bottom_sheet` | `banner_top` | `banner_bottom` | `center` | `fullscreen`.
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

  /// The look designed in the console. Null for messages made before the
  /// designer — those render from [title] / [body] / [imageUrl] / [buttons].
  final NexusInAppDesign? design;

  /// The A/B variant this user was assigned (null when the message has no test).
  final String? variantId;

  /// A "send test" from the console: shown at once, outside triggers and caps,
  /// never reported.
  final bool isTest;

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
      design: NexusInAppDesign.tryParse(content['design']),
      variantId: j['variantId']?.toString(),
      isTest: j['test'] == true,
    );
  }
}
