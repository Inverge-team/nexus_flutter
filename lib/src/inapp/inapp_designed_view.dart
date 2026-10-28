import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'inapp_design.dart';
import 'inapp_models.dart';

/// Space kept clear beside the close button.
const double _closeInset = 28;

/// Renders a message designed in the Nexus console: backdrop, placement for the
/// layout, entrance animation, auto-dismiss, and the block stack.
///
/// Layout rules match the console preview exactly (padding, gap, edge-to-edge
/// images, the close-button inset, shadows) — that is what makes the preview
/// trustworthy. Fills the space it is given; [NexusInAppOverlay] gives it the
/// whole screen.
class NexusInAppDesignedView extends StatefulWidget {
  const NexusInAppDesignedView({
    super.key,
    required this.message,
    required this.design,
    required this.onButton,
    required this.onDismiss,
  });

  final NexusInAppMessage message;
  final NexusInAppDesign design;
  final void Function(NexusInAppButton button) onButton;
  final VoidCallback onDismiss;

  @override
  State<NexusInAppDesignedView> createState() => _NexusInAppDesignedViewState();
}

class _NexusInAppDesignedViewState extends State<NexusInAppDesignedView> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.design.animation == 'none' ? 0 : 300),
  )..forward();
  Timer? _autoDismiss;

  String get _layout => widget.message.layout;
  bool get _banner => _layout == 'banner_top' || _layout == 'banner_bottom';
  bool get _sheet => _layout == 'bottom_sheet';
  bool get _full => _layout == 'fullscreen';
  bool get _hasBackdrop => !_banner && !_full;

  @override
  void initState() {
    super.initState();
    final s = widget.design.autoDismissSeconds;
    if (s > 0) _autoDismiss = Timer(Duration(seconds: s), widget.onDismiss);
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.design;
    final media = MediaQuery.of(context);
    final dir = d.resolveDirection(Directionality.of(context));
    final curved = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);

    Widget frame = _Frame(
      message: widget.message,
      design: d,
      safeTop: media.padding.top,
      safeBottom: media.padding.bottom,
      maxHeight: media.size.height,
      onButton: widget.onButton,
      onDismiss: widget.onDismiss,
    );
    frame = _entrance(frame, curved);

    final Widget placed = switch (_layout) {
      'banner_top' => Align(
          alignment: Alignment.topCenter,
          child: Padding(padding: EdgeInsets.fromLTRB(10, media.padding.top + 6, 10, 0), child: frame),
        ),
      'banner_bottom' => Align(
          alignment: Alignment.bottomCenter,
          child: Padding(padding: EdgeInsets.fromLTRB(10, 0, 10, media.padding.bottom + 6), child: frame),
        ),
      'bottom_sheet' => Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: frame),
        ),
      'fullscreen' => Positioned.fill(child: frame),
      _ => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(constraints: BoxConstraints(maxWidth: d.frame.maxWidth), child: frame),
          ),
        ),
    };

    return Directionality(
      textDirection: dir,
      child: Stack(
        children: [
          if (_hasBackdrop)
            Positioned.fill(
              child: FadeTransition(
                opacity: curved,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: d.dismissOnBackdropTap ? widget.onDismiss : null,
                  child: ColoredBox(color: d.overlayColor),
                ),
              ),
            ),
          if (placed is Positioned) placed else Positioned.fill(child: placed),
        ],
      ),
    );
  }

  Widget _entrance(Widget child, Animation<double> t) {
    switch (widget.design.animation) {
      case 'zoom':
        return FadeTransition(
          opacity: t,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.88, end: 1).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutBack)),
            child: child,
          ),
        );
      case 'slide':
        final from = _layout == 'banner_top'
            ? const Offset(0, -0.3)
            : _sheet
                ? const Offset(0, 1)
                : const Offset(0, 0.15);
        final slide = SlideTransition(position: Tween<Offset>(begin: from, end: Offset.zero).animate(t), child: child);
        return _sheet ? slide : FadeTransition(opacity: t, child: slide);
      case 'none':
        return child;
      default:
        return FadeTransition(opacity: t, child: child);
    }
  }
}

class _Frame extends StatelessWidget {
  const _Frame({
    required this.message,
    required this.design,
    required this.safeTop,
    required this.safeBottom,
    required this.maxHeight,
    required this.onButton,
    required this.onDismiss,
  });

  final NexusInAppMessage message;
  final NexusInAppDesign design;
  final double safeTop;
  final double safeBottom;
  final double maxHeight;
  final void Function(NexusInAppButton button) onButton;
  final VoidCallback onDismiss;

  bool get _banner => message.layout == 'banner_top' || message.layout == 'banner_bottom';
  bool get _sheet => message.layout == 'bottom_sheet';
  bool get _full => message.layout == 'fullscreen';

  @override
  Widget build(BuildContext context) {
    final f = design.frame;
    final close = design.close;
    final blocks = design.blocks;
    final pad = f.padding;
    final padTop = pad + (_full ? safeTop : _sheet ? 10 : 0);
    final padBottom = pad + (_full || _sheet ? safeBottom : 0);
    final firstBleed = blocks.isNotEmpty && blocks.first is NexusInAppImageBlock && (blocks.first as NexusInAppImageBlock).bleed;
    final lastBleed = blocks.isNotEmpty && blocks.last is NexusInAppImageBlock && (blocks.last as NexusInAppImageBlock).bleed;
    // Banners keep the whole column clear of the ✕; other layouts only the first block.
    final endInsetAll = _banner && close.show ? _closeInset : 0.0;

    final children = <Widget>[];
    if (!firstBleed) children.add(SizedBox(height: padTop));
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (i > 0) children.add(SizedBox(height: f.gap));
      final bleed = (b is NexusInAppImageBlock && b.bleed) || (b is NexusInAppCarouselBlock && b.bleed);
      final endInset = endInsetAll + (i == 0 && close.show && !_banner && !bleed ? _closeInset : 0);
      // An edge-to-edge carousel still starts its first card in line with the content.
      final block = b is NexusInAppCarouselBlock
          ? _Carousel(block: b, inset: b.bleed ? pad : 0, onButton: onButton, toButton: _toButton)
          : _block(context, b);
      children.add(bleed ? block : Padding(padding: EdgeInsetsDirectional.only(start: pad, end: pad + endInset), child: block));
    }
    if (!lastBleed) children.add(SizedBox(height: padBottom));

    Widget column = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);

    final radius = _full
        ? BorderRadius.zero
        : _sheet
            ? BorderRadius.vertical(top: Radius.circular(f.radius))
            : BorderRadius.circular(f.radius);

    Widget body;
    if (_full) {
      body = LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: Column(
              mainAxisAlignment: firstBleed ? MainAxisAlignment.start : MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [column],
            ),
          ),
        ),
      );
    } else {
      // Never taller than the screen allows; scroll inside the frame instead.
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight * (_banner ? 0.5 : 0.88)),
        child: SingleChildScrollView(child: column),
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          color: f.background,
          gradient: f.backgroundKind == 'gradient' ? _gradient(f) : null,
          image: f.backgroundKind == 'image' && (f.backgroundImageUrl ?? '').isNotEmpty
              ? DecorationImage(image: NetworkImage(f.backgroundImageUrl!), fit: BoxFit.cover, onError: (_, _) {})
              : null,
          borderRadius: radius,
          border: f.borderWidth > 0 && !_full ? Border.all(color: f.borderColor, width: f.borderWidth) : null,
          boxShadow: _full ? null : _shadow(f.shadow),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            body,
            if (_sheet)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(color: close.color.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
              ),
            if (close.show)
              PositionedDirectional(
                top: (_full ? safeTop : _sheet ? 14 : 0) + (_banner ? 8 : 10),
                start: close.atStart ? 10 : null,
                end: close.atStart ? null : 10,
                child: _CloseButton(close: close, onTap: onDismiss),
              ),
          ],
        ),
      ),
    );
  }

  Widget _block(BuildContext context, NexusInAppBlock b) {
    switch (b) {
      case NexusInAppImageBlock():
        Widget img = Image.network(
          b.url,
          width: double.infinity,
          fit: b.contain ? BoxFit.contain : (b.aspectRatio == null ? BoxFit.fitWidth : BoxFit.cover),
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        );
        if (b.aspectRatio != null) img = AspectRatio(aspectRatio: b.aspectRatio!, child: img);
        if (b.radius > 0) img = ClipRRect(borderRadius: BorderRadius.circular(b.radius), child: img);
        final tap = b.tap;
        if (tap == null) return img;
        // Reported as a click with the image block's id.
        return GestureDetector(
          onTap: () => onButton(NexusInAppButton(id: b.id, text: '', action: tap.action, url: tap.url, event: tap.event)),
          child: img,
        );
      case NexusInAppBadgeBlock():
        return Align(
          alignment: _alignment(b.align),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: b.background, borderRadius: BorderRadius.circular(999)),
            child: Text(
              b.text,
              style: TextStyle(color: b.foreground, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5, height: 1.2),
            ),
          ),
        );
      case NexusInAppHeadingBlock():
        return Text(
          b.text,
          textAlign: _textAlign(b.align),
          style: TextStyle(color: b.color, fontSize: b.size, fontWeight: _weight(b.weight), height: 1.25),
        );
      case NexusInAppTextBlock():
        return Text(
          b.text,
          textAlign: _textAlign(b.align),
          style: TextStyle(color: b.color, fontSize: b.size, height: b.lineHeight),
        );
      case NexusInAppButtonsBlock():
        final buttons = [for (final i in b.items) _DesignButton(button: i, onTap: () => onButton(_toButton(i)))];
        if (b.row) {
          return Row(
            children: [
              for (var i = 0; i < buttons.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: buttons[i]),
              ],
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < buttons.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              buttons[i],
            ],
          ],
        );
      case NexusInAppCarouselBlock():
        return const SizedBox.shrink(); // built by _Carousel, which keeps its own page state
      case NexusInAppSpacerBlock():
        return SizedBox(height: b.height);
      case NexusInAppDividerBlock():
        return Container(
          height: b.thickness,
          decoration: BoxDecoration(color: b.color, borderRadius: BorderRadius.circular(b.thickness)),
        );
    }
  }

  static NexusInAppButton _toButton(NexusInAppDesignButton i) => NexusInAppButton(
        id: i.id,
        text: i.text,
        action: i.action,
        url: i.url,
        event: i.event,
        value: i.value,
        style: i.variant == 'filled' ? 'primary' : i.variant == 'outline' ? 'secondary' : 'text',
      );

  static LinearGradient _gradient(NexusInAppFrame f) {
    // CSS angles: 0° points up, clockwise. Alignment y grows downward.
    final rad = f.gradientAngle * math.pi / 180;
    final end = Alignment(math.sin(rad), -math.cos(rad));
    return LinearGradient(begin: -end, end: end, colors: [f.background, f.background2]);
  }

  static List<BoxShadow>? _shadow(String s) => switch (s) {
        'sm' => const [BoxShadow(color: Color(0x1F000000), blurRadius: 6, offset: Offset(0, 2))],
        'md' => const [BoxShadow(color: Color(0x2E000000), blurRadius: 18, offset: Offset(0, 6))],
        'lg' => const [BoxShadow(color: Color(0x47000000), blurRadius: 36, offset: Offset(0, 14))],
        _ => null,
      };

  static TextAlign _textAlign(String a) => switch (a) {
        'center' => TextAlign.center,
        'end' => TextAlign.end,
        _ => TextAlign.start,
      };

  static AlignmentDirectional _alignment(String a) => switch (a) {
        'center' => AlignmentDirectional.center,
        'end' => AlignmentDirectional.centerEnd,
        _ => AlignmentDirectional.centerStart,
      };

  static FontWeight _weight(int w) => switch (w) {
        <= 400 => FontWeight.w400,
        <= 500 => FontWeight.w500,
        <= 600 => FontWeight.w600,
        <= 700 => FontWeight.w700,
        _ => FontWeight.w800,
      };
}

class _DesignButton extends StatelessWidget {
  const _DesignButton({required this.button, required this.onTap, this.compact = false});
  final NexusInAppDesignButton button;
  final VoidCallback onTap;

  /// Carousel cards: 40 px tall, 14 px label.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final b = button;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(b.radius),
      side: b.variant == 'outline' ? BorderSide(color: b.background, width: 1.5) : BorderSide.none,
    );
    return Material(
      color: b.variant == 'filled' ? b.background : Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: compact ? 40 : 46),
          child: Padding(
            padding: compact ? const EdgeInsets.symmetric(horizontal: 12, vertical: 9) : const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (b.action == 'copy') ...[
                  Icon(Icons.copy_rounded, size: 15, color: b.foreground),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    b.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: b.foreground, fontSize: compact ? 14 : 15, fontWeight: FontWeight.w600, height: 1.2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.close, required this.onTap});
  final NexusInAppClose close;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Circle: a contrasting disc so the ✕ reads over photos. "Dark" = more
    // contrast against white than black (luminance under ~0.179) — the console's rule.
    final dark = close.color.computeLuminance() < 0.179;
    return Semantics(
      button: true,
      label: 'Close',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: close.circle ? (dark ? const Color(0xCCFFFFFF) : const Color(0x59000000)) : Colors.transparent,
          ),
          child: Icon(Icons.close_rounded, size: 18, color: close.color),
        ),
      ),
    );
  }
}

/// A swipeable row of cards. Same rules as the console preview: 84% wide with
/// peek (else full width), shared image shape, every card as tall as the
/// tallest with its button pinned to the bottom, page dots, optional autoplay
/// that loops and restarts after a swipe.
class _Carousel extends StatefulWidget {
  const _Carousel({required this.block, required this.inset, required this.onButton, required this.toButton});
  final NexusInAppCarouselBlock block;

  /// Horizontal padding inside the scroll view (edge-to-edge carousels).
  final double inset;
  final void Function(NexusInAppButton button) onButton;
  final NexusInAppButton Function(NexusInAppDesignButton b) toButton;

  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  final _scroll = ScrollController();
  Timer? _autoplay;
  int _index = 0;
  double _step = 1;

  NexusInAppCarouselBlock get b => widget.block;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final i = (_scroll.offset / _step).round().clamp(0, b.cards.length - 1);
      if (i != _index && mounted) setState(() => _index = i);
    });
    _arm();
  }

  void _arm() {
    _autoplay?.cancel();
    if (b.autoplaySeconds <= 0 || b.cards.length < 2) return;
    _autoplay = Timer.periodic(Duration(seconds: b.autoplaySeconds), (_) => _go((_index + 1) % b.cards.length));
  }

  void _go(int i) {
    if (!_scroll.hasClients) return;
    final target = (i * _step).clamp(0.0, _scroll.position.maxScrollExtent);
    unawaited(_scroll.animateTo(target, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _autoplay?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final viewport = c.maxWidth - widget.inset * 2;
      final cardW = b.peek && b.cards.length > 1 ? viewport * 0.84 : viewport;
      _step = cardW + b.gap;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          NotificationListener<ScrollStartNotification>(
            // A swipe restarts the autoplay clock, so it never yanks a card away mid-read.
            onNotification: (n) {
              if (n.dragDetails != null) _arm();
              return false;
            },
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              physics: _SnapPhysics(extent: _step),
              padding: EdgeInsets.symmetric(horizontal: widget.inset),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < b.cards.length; i++) ...[
                      if (i > 0) SizedBox(width: b.gap),
                      SizedBox(width: cardW, child: _card(b.cards[i])),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (b.showIndicator && b.cards.length > 1) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < b.cards.length; i++)
                  GestureDetector(
                    onTap: () => _go(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 2.5),
                      width: i == _index ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: b.indicatorColor.withValues(alpha: i == _index ? 1 : 0.28),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      );
    });
  }

  Widget _card(NexusInAppCarouselCard c) {
    final align = switch (c.align) {
      'center' => TextAlign.center,
      'end' => TextAlign.end,
      _ => TextAlign.start,
    };
    final cross = switch (c.align) {
      'center' => CrossAxisAlignment.center,
      'end' => CrossAxisAlignment.end,
      _ => CrossAxisAlignment.start,
    };
    final hasText = c.title.isNotEmpty || c.body.isNotEmpty || c.button != null;
    Widget card = Container(
      decoration: BoxDecoration(color: c.background, borderRadius: BorderRadius.circular(b.radius)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (c.imageUrl != null)
            AspectRatio(
              aspectRatio: b.aspectRatio,
              child: Image.network(
                c.imageUrl!,
                fit: b.contain ? BoxFit.contain : BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          if (hasText)
            Expanded(
              child: Padding(
                padding: EdgeInsets.all(b.padding),
                child: Column(
                  crossAxisAlignment: cross,
                  children: [
                    if (c.title.isNotEmpty)
                      Text(c.title,
                          textAlign: align,
                          style: TextStyle(color: c.titleColor, fontSize: b.titleSize, fontWeight: FontWeight.w700, height: 1.25)),
                    if (c.title.isNotEmpty && c.body.isNotEmpty) const SizedBox(height: 4),
                    if (c.body.isNotEmpty)
                      Text(c.body, textAlign: align, style: TextStyle(color: c.bodyColor, fontSize: b.bodySize, height: 1.4)),
                    if (c.button != null) ...[
                      // Pinned to the bottom, so buttons line up across cards of different lengths.
                      const Spacer(),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: _DesignButton(button: c.button!, compact: true, onTap: () => widget.onButton(widget.toButton(c.button!))),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    final tap = c.tap;
    if (tap != null) {
      card = GestureDetector(
        onTap: () => widget.onButton(NexusInAppButton(id: c.id, text: '', action: tap.action, url: tap.url, event: tap.event)),
        child: card,
      );
    }
    return card;
  }
}

/// Settles on card boundaries — `PageScrollPhysics` would snap to the viewport,
/// which is wrong once the next card peeks in.
class _SnapPhysics extends ScrollPhysics {
  const _SnapPhysics({required this.extent, super.parent});
  final double extent;

  @override
  _SnapPhysics applyTo(ScrollPhysics? ancestor) => _SnapPhysics(extent: extent, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    var page = position.pixels / extent;
    if (velocity < -tolerance.velocity) {
      page -= 0.5;
    } else if (velocity > tolerance.velocity) {
      page += 0.5;
    }
    final target = (page.roundToDouble() * extent).clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(spring, position.pixels, target, velocity, tolerance: tolerance);
  }

  @override
  bool get allowImplicitScrolling => false;
}
