import 'package:flutter/material.dart';

import 'inapp_models.dart';

/// Default rendering for an in-app message. Bring your own UI via
/// `NexusInAppOverlay(messageBuilder: ...)` if you'd rather.
class NexusInAppView extends StatelessWidget {
  const NexusInAppView({
    super.key,
    required this.message,
    required this.onButton,
    required this.onDismiss,
  });

  final NexusInAppMessage message;
  final void Function(NexusInAppButton button) onButton;
  final VoidCallback onDismiss;

  bool get _isBanner => message.layout == 'banner_top' || message.layout == 'banner_bottom';
  bool get _isFullscreen => message.layout == 'fullscreen';

  @override
  Widget build(BuildContext context) {
    final bg = _color(message.backgroundColor) ?? Theme.of(context).cardColor;
    final fg = _color(message.textColor) ?? Theme.of(context).textTheme.bodyLarge?.color ?? Colors.black;
    return _isBanner ? _banner(context, bg, fg) : _card(context, bg, fg);
  }

  Widget _banner(BuildContext context, Color bg, Color fg) {
    return Material(
      color: bg,
      elevation: 6,
      child: SafeArea(
        top: message.layout == 'banner_top',
        bottom: message.layout == 'banner_bottom',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              if (message.imageUrl != null) ...[
                _thumb(message.imageUrl!, 40),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: _texts(fg, dense: true),
                ),
              ),
              ..._buttons(context, fg, compact: true),
              IconButton(icon: Icon(Icons.close, color: fg.withValues(alpha: 0.7)), onPressed: onDismiss),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, Color bg, Color fg) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (message.imageUrl != null)
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            child: AspectRatio(aspectRatio: 16 / 9, child: _thumb(message.imageUrl!, null)),
          ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._texts(fg),
              if (message.buttons.isNotEmpty) ...[
                const SizedBox(height: 18),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: _buttons(context, fg)),
              ],
            ],
          ),
        ),
      ],
    );

    if (_isFullscreen) {
      return Material(
        color: bg,
        child: SafeArea(
          child: Stack(
            children: [
              Align(alignment: Alignment.topRight, child: IconButton(icon: Icon(Icons.close, color: fg), onPressed: onDismiss)),
              Center(child: SingleChildScrollView(child: content)),
            ],
          ),
        ),
      );
    }

    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            content,
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                iconSize: 20,
                icon: Icon(Icons.close, color: fg.withValues(alpha: 0.7)),
                onPressed: onDismiss,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _texts(Color fg, {bool dense = false}) => [
        if (message.title != null && message.title!.isNotEmpty)
          Text(
            message.title!,
            style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: dense ? 15 : 18),
          ),
        if (message.body != null && message.body!.isNotEmpty) ...[
          if (message.title != null) SizedBox(height: dense ? 2 : 8),
          Text(message.body!, style: TextStyle(color: fg.withValues(alpha: 0.85), fontSize: dense ? 13 : 15)),
        ],
      ];

  List<Widget> _buttons(BuildContext context, Color fg, {bool compact = false}) {
    return [
      for (final b in message.buttons)
        Padding(
          padding: EdgeInsets.only(left: compact ? 6 : 8),
          child: b.style == 'secondary' || b.style == 'text'
              ? TextButton(onPressed: () => onButton(b), child: Text(b.text))
              : FilledButton(onPressed: () => onButton(b), child: Text(b.text)),
        ),
    ];
  }

  Widget _thumb(String url, double? size) => Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => const SizedBox.shrink(),
      );

  static Color? _color(String? hex) {
    if (hex == null) return null;
    var h = hex.replaceFirst('#', '').trim();
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return null;
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : Color(v);
  }
}
