import 'package:flutter/painting.dart';

/// The designed look of an in-app message — built in the Nexus console's
/// designer and delivered as `content.design`.
///
/// A vertical stack of [blocks] inside a styled frame. The backend validates
/// and clamps every value before it is stored, so parsing here is lenient:
/// anything missing falls back to the console's defaults, and an unknown block
/// type is skipped rather than failing the whole message.
class NexusInAppDesign {
  const NexusInAppDesign({
    required this.blocks,
    required this.frame,
    required this.overlayColor,
    required this.dismissOnBackdropTap,
    required this.close,
    required this.animation,
    required this.autoDismissSeconds,
    required this.direction,
  });

  final List<NexusInAppBlock> blocks;
  final NexusInAppFrame frame;

  /// Backdrop colour, opacity included (modal / sheet / center only).
  final Color overlayColor;
  final bool dismissOnBackdropTap;
  final NexusInAppClose close;

  /// `fade` | `slide` | `zoom` | `none`.
  final String animation;

  /// 0 = stays until dismissed.
  final int autoDismissSeconds;

  /// `auto` | `ltr` | `rtl`.
  final String direction;

  static NexusInAppDesign? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final blocks = (j['blocks'] as List?)
            ?.whereType<Map>()
            .map((b) => NexusInAppBlock.tryParse(b.cast<String, dynamic>()))
            .whereType<NexusInAppBlock>()
            .toList() ??
        const <NexusInAppBlock>[];
    if (blocks.isEmpty) return null;
    final overlay = _map(j['overlay']);
    final close = _map(j['close']);
    return NexusInAppDesign(
      blocks: blocks,
      frame: NexusInAppFrame._parse(_map(j['frame'])),
      overlayColor: (parseHex(overlay['color']) ?? const Color(0xFF0B1220))
          .withValues(alpha: _num(overlay['opacity'], 0.55).clamp(0.0, 0.95)),
      dismissOnBackdropTap: overlay['dismissOnTap'] != false,
      close: NexusInAppClose(
        show: close['show'] != false,
        circle: close['style'] == 'circle',
        color: parseHex(close['color']) ?? const Color(0xFF6B7280),
        atStart: close['position'] == 'start',
      ),
      animation: _str(j['animation'], 'fade'),
      autoDismissSeconds: _num(j['autoDismiss'], 0).round(),
      direction: _str(j['dir'], 'auto'),
    );
  }

  /// `auto` follows the copy: right-to-left when the first strong character is
  /// Arabic / Hebrew script — the same rule the console preview uses.
  TextDirection resolveDirection(TextDirection ambient) {
    if (direction == 'rtl') return TextDirection.rtl;
    if (direction == 'ltr') return TextDirection.ltr;
    for (final b in blocks) {
      final text = switch (b) {
        NexusInAppHeadingBlock(:final text) || NexusInAppTextBlock(:final text) || NexusInAppBadgeBlock(:final text) => text,
        NexusInAppButtonsBlock(:final items) => items.map((i) => i.text).join(' '),
        NexusInAppCarouselBlock(:final cards) => cards.map((c) => '${c.title} ${c.body}').join(' '),
        _ => '',
      };
      for (final r in text.runes) {
        if (_isRtl(r)) return TextDirection.rtl;
        if (_isLtr(r)) return TextDirection.ltr;
      }
    }
    return ambient;
  }

  static bool _isRtl(int r) =>
      (r >= 0x0590 && r <= 0x08FF) || (r >= 0xFB1D && r <= 0xFDFF) || (r >= 0xFE70 && r <= 0xFEFF);
  static bool _isLtr(int r) =>
      (r >= 0x41 && r <= 0x5A) ||
      (r >= 0x61 && r <= 0x7A) ||
      (r >= 0xC0 && r <= 0x24F) ||
      (r >= 0x370 && r <= 0x3FF) ||
      (r >= 0x400 && r <= 0x4FF);
}

class NexusInAppFrame {
  const NexusInAppFrame({
    required this.background,
    required this.background2,
    required this.backgroundKind,
    required this.gradientAngle,
    this.backgroundImageUrl,
    required this.radius,
    required this.padding,
    required this.gap,
    required this.maxWidth,
    required this.shadow,
    required this.borderColor,
    required this.borderWidth,
  });

  final Color background;
  final Color background2;

  /// `solid` | `gradient` | `image`.
  final String backgroundKind;

  /// CSS degrees: 180 = top to bottom.
  final double gradientAngle;
  final String? backgroundImageUrl;
  final double radius;
  final double padding;
  final double gap;
  final double maxWidth;

  /// `none` | `sm` | `md` | `lg`.
  final String shadow;
  final Color borderColor;
  final double borderWidth;

  factory NexusInAppFrame._parse(Map<String, dynamic> f) {
    final bg = _map(f['background']);
    final color = parseHex(bg['color']) ?? const Color(0xFFFFFFFF);
    return NexusInAppFrame(
      background: color,
      background2: parseHex(bg['color2']) ?? color,
      backgroundKind: _str(bg['kind'], 'solid'),
      gradientAngle: _num(bg['angle'], 180),
      backgroundImageUrl: bg['imageUrl']?.toString(),
      radius: _num(f['radius'], 18),
      padding: _num(f['padding'], 22),
      gap: _num(f['gap'], 12),
      maxWidth: _num(f['width'], 340),
      shadow: _str(f['shadow'], 'md'),
      borderColor: parseHex(f['borderColor']) ?? const Color(0xFFE5E7EB),
      borderWidth: _num(f['borderWidth'], 0),
    );
  }
}

class NexusInAppClose {
  const NexusInAppClose({required this.show, required this.circle, required this.color, required this.atStart});
  final bool show;
  final bool circle;
  final Color color;
  final bool atStart;
}

/// What tapping an image does.
class NexusInAppTap {
  const NexusInAppTap({required this.action, this.url, this.event});

  /// `dismiss` | `url` | `event`.
  final String action;
  final String? url;
  final String? event;
}

/// One block of a designed message.
sealed class NexusInAppBlock {
  const NexusInAppBlock(this.id);
  final String id;

  static NexusInAppBlock? tryParse(Map<String, dynamic> j) {
    final id = (j['id'] ?? '').toString();
    switch (j['type']) {
      case 'image':
        final url = j['url']?.toString() ?? '';
        if (url.isEmpty) return null;
        final tap = j['tap'] is Map ? _map(j['tap']) : null;
        return NexusInAppImageBlock(
          id,
          url: url,
          aspectRatio: switch (j['aspect']) {
            '16:9' => 16 / 9,
            '4:3' => 4 / 3,
            '1:1' => 1.0,
            '3:4' => 3 / 4,
            _ => null,
          },
          contain: j['fit'] == 'contain',
          radius: _num(j['radius'], 0),
          bleed: j['bleed'] == true,
          tap: tap == null
              ? null
              : NexusInAppTap(action: _str(tap['action'], 'dismiss'), url: tap['url']?.toString(), event: tap['event']?.toString()),
        );
      case 'badge':
        return NexusInAppBadgeBlock(
          id,
          text: _str(j['text'], ''),
          background: parseHex(j['bg']) ?? const Color(0xFFEEF2FF),
          foreground: parseHex(j['fg']) ?? const Color(0xFF4338CA),
          align: _str(j['align'], 'start'),
        );
      case 'heading':
        return NexusInAppHeadingBlock(
          id,
          text: _str(j['text'], ''),
          size: _num(j['size'], 22),
          weight: _num(j['weight'], 700).round(),
          color: parseHex(j['color']) ?? const Color(0xFF111827),
          align: _str(j['align'], 'start'),
        );
      case 'text':
        return NexusInAppTextBlock(
          id,
          text: _str(j['text'], ''),
          size: _num(j['size'], 15),
          color: parseHex(j['color']) ?? const Color(0xFF4B5563),
          align: _str(j['align'], 'start'),
          lineHeight: _num(j['lineHeight'], 1.45),
        );
      case 'buttons':
        final items = (j['items'] as List?)
                ?.whereType<Map>()
                .map((i) => NexusInAppDesignButton._parse(i.cast<String, dynamic>()))
                .toList() ??
            const <NexusInAppDesignButton>[];
        if (items.isEmpty) return null;
        return NexusInAppButtonsBlock(id, row: j['layout'] == 'row', items: items);
      case 'carousel':
        final cards = (j['cards'] as List?)
                ?.whereType<Map>()
                .map((c) => NexusInAppCarouselCard._parse(c.cast<String, dynamic>()))
                .toList() ??
            const <NexusInAppCarouselCard>[];
        if (cards.isEmpty) return null;
        final ind = _map(j['indicator']);
        return NexusInAppCarouselBlock(
          id,
          cards: cards,
          aspectRatio: switch (j['aspect']) {
            '16:9' => 16 / 9,
            '1:1' => 1.0,
            '3:4' => 3 / 4,
            _ => 4 / 3,
          },
          contain: j['fit'] == 'contain',
          peek: j['peek'] != false,
          bleed: j['bleed'] == true,
          radius: _num(j['radius'], 14),
          gap: _num(j['gap'], 10),
          padding: _num(j['padding'], 12),
          titleSize: _num(j['titleSize'], 17),
          bodySize: _num(j['bodySize'], 14),
          showIndicator: ind['show'] != false,
          indicatorColor: parseHex(ind['color']) ?? const Color(0xFF4F46E5),
          autoplaySeconds: _num(j['autoplay'], 0).round(),
        );
      case 'spacer':
        return NexusInAppSpacerBlock(id, height: _num(j['height'], 16));
      case 'divider':
        return NexusInAppDividerBlock(id, color: parseHex(j['color']) ?? const Color(0xFFE5E7EB), thickness: _num(j['thickness'], 1));
      default:
        return null;
    }
  }
}

class NexusInAppImageBlock extends NexusInAppBlock {
  const NexusInAppImageBlock(super.id,
      {required this.url, this.aspectRatio, required this.contain, required this.radius, required this.bleed, this.tap});
  final String url;

  /// Null = the image's own ratio.
  final double? aspectRatio;
  final bool contain;
  final double radius;

  /// Edge to edge — ignores the frame's padding.
  final bool bleed;
  final NexusInAppTap? tap;
}

class NexusInAppBadgeBlock extends NexusInAppBlock {
  const NexusInAppBadgeBlock(super.id, {required this.text, required this.background, required this.foreground, required this.align});
  final String text;
  final Color background;
  final Color foreground;
  final String align;
}

class NexusInAppHeadingBlock extends NexusInAppBlock {
  const NexusInAppHeadingBlock(super.id,
      {required this.text, required this.size, required this.weight, required this.color, required this.align});
  final String text;
  final double size;
  final int weight;
  final Color color;
  final String align;
}

class NexusInAppTextBlock extends NexusInAppBlock {
  const NexusInAppTextBlock(super.id,
      {required this.text, required this.size, required this.color, required this.align, required this.lineHeight});
  final String text;
  final double size;
  final Color color;
  final String align;
  final double lineHeight;
}

class NexusInAppButtonsBlock extends NexusInAppBlock {
  const NexusInAppButtonsBlock(super.id, {required this.row, required this.items});

  /// Side by side (true) or stacked full-width (false).
  final bool row;
  final List<NexusInAppDesignButton> items;
}

/// A swipeable row of up to 10 cards. Cards share the image shape and type
/// sizes; all are as tall as the tallest, with buttons pinned to the bottom.
class NexusInAppCarouselBlock extends NexusInAppBlock {
  const NexusInAppCarouselBlock(
    super.id, {
    required this.cards,
    required this.aspectRatio,
    required this.contain,
    required this.peek,
    required this.bleed,
    required this.radius,
    required this.gap,
    required this.padding,
    required this.titleSize,
    required this.bodySize,
    required this.showIndicator,
    required this.indicatorColor,
    required this.autoplaySeconds,
  });
  final List<NexusInAppCarouselCard> cards;
  final double aspectRatio;
  final bool contain;

  /// Show the edge of the next card (cards are 84% wide).
  final bool peek;

  /// Edge to edge — ignores the frame's side padding.
  final bool bleed;
  final double radius;
  final double gap;
  final double padding;
  final double titleSize;
  final double bodySize;
  final bool showIndicator;
  final Color indicatorColor;

  /// 0 = only by swiping.
  final int autoplaySeconds;
}

class NexusInAppCarouselCard {
  const NexusInAppCarouselCard({
    required this.id,
    this.imageUrl,
    required this.title,
    required this.body,
    this.button,
    this.tap,
    required this.background,
    required this.titleColor,
    required this.bodyColor,
    required this.align,
  });

  /// Reported as the click's `buttonId` when the card itself is tapped.
  final String id;
  final String? imageUrl;
  final String title;
  final String body;
  final NexusInAppDesignButton? button;
  final NexusInAppTap? tap;
  final Color background;
  final Color titleColor;
  final Color bodyColor;
  final String align;

  factory NexusInAppCarouselCard._parse(Map<String, dynamic> j) {
    final tap = j['tap'] is Map ? _map(j['tap']) : null;
    final img = j['imageUrl']?.toString();
    return NexusInAppCarouselCard(
      id: (j['id'] ?? '').toString(),
      imageUrl: img == null || img.isEmpty ? null : img,
      title: _str(j['title'], ''),
      body: _str(j['body'], ''),
      button: j['button'] is Map ? NexusInAppDesignButton._parse(_map(j['button'])) : null,
      tap: tap == null
          ? null
          : NexusInAppTap(action: _str(tap['action'], 'dismiss'), url: tap['url']?.toString(), event: tap['event']?.toString()),
      background: parseHex(j['bg']) ?? const Color(0xFFF3F4F6),
      titleColor: parseHex(j['titleColor']) ?? const Color(0xFF111827),
      bodyColor: parseHex(j['bodyColor']) ?? const Color(0xFF4B5563),
      align: _str(j['align'], 'start'),
    );
  }
}

class NexusInAppSpacerBlock extends NexusInAppBlock {
  const NexusInAppSpacerBlock(super.id, {required this.height});
  final double height;
}

class NexusInAppDividerBlock extends NexusInAppBlock {
  const NexusInAppDividerBlock(super.id, {required this.color, required this.thickness});
  final Color color;
  final double thickness;
}

class NexusInAppDesignButton {
  const NexusInAppDesignButton({
    required this.id,
    required this.text,
    required this.action,
    this.url,
    this.event,
    this.value,
    required this.variant,
    required this.background,
    required this.foreground,
    required this.radius,
  });

  final String id;
  final String text;

  /// `dismiss` | `url` | `event` | `copy`.
  final String action;
  final String? url;
  final String? event;

  /// For `copy`: the text put on the clipboard.
  final String? value;

  /// `filled` | `outline` | `text`.
  final String variant;

  /// Fill (filled) or border (outline) colour.
  final Color background;

  /// Label colour.
  final Color foreground;
  final double radius;

  factory NexusInAppDesignButton._parse(Map<String, dynamic> j) => NexusInAppDesignButton(
        id: (j['id'] ?? '').toString(),
        text: _str(j['text'], ''),
        action: _str(j['action'], 'dismiss'),
        url: j['url']?.toString(),
        event: j['event']?.toString(),
        value: j['value']?.toString(),
        variant: _str(j['variant'], 'filled'),
        background: parseHex(j['bg']) ?? const Color(0xFF4F46E5),
        foreground: parseHex(j['fg']) ?? const Color(0xFFFFFFFF),
        radius: _num(j['radius'], 12),
      );
}

/// `#RRGGBB` (the designer's format) or `#AARRGGBB` → a [Color].
Color? parseHex(Object? hex) {
  if (hex is! String) return null;
  var h = hex.replaceFirst('#', '').trim();
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}

Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};
String _str(Object? v, String fallback) => v is String ? v : fallback;
double _num(Object? v, double fallback) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) ?? fallback : fallback);
