import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_flutter/nexus.dart';

/// What `/partner/inapp/active` returns for a message made in the console's
/// designer (the backend's sanitizer output — every field present).
Map<String, Object?> _message({String layout = 'modal', Map<String, Object?> design = const {}}) => {
      'id': 'm1',
      'layout': layout,
      'content': {
        'title': 'Legacy title',
        'body': 'Legacy body',
        'design': {
          'v': 1,
          'blocks': [
            {'id': 'bdg', 'type': 'badge', 'text': 'NEW', 'bg': '#EEF2FF', 'fg': '#4338CA', 'align': 'start'},
            {'id': 'h', 'type': 'heading', 'text': 'Dark mode is here', 'size': 22, 'weight': 700, 'color': '#111827', 'align': 'start'},
            {'id': 't', 'type': 'text', 'text': 'Easier on the eyes.', 'size': 15, 'color': '#4B5563', 'align': 'center', 'lineHeight': 1.45},
            {'id': 's', 'type': 'spacer', 'height': 8},
            {'id': 'd', 'type': 'divider', 'color': '#E5E7EB', 'thickness': 1},
            {
              'id': 'b',
              'type': 'buttons',
              'layout': 'row',
              'items': [
                {'id': 'copy', 'text': 'Copy SAVE20', 'action': 'copy', 'value': 'SAVE20', 'variant': 'filled', 'bg': '#4F46E5', 'fg': '#FFFFFF', 'radius': 12},
                {'id': 'later', 'text': 'Later', 'action': 'dismiss', 'variant': 'text', 'bg': '#4F46E5', 'fg': '#4F46E5', 'radius': 12},
              ],
            },
            {'id': 'x', 'type': 'hologram'}, // unknown → skipped, not fatal
          ],
          'frame': {
            'background': {'kind': 'gradient', 'color': '#FFFFFF', 'color2': '#EEF2FF', 'angle': 180},
            'radius': 18, 'padding': 22, 'gap': 12, 'width': 340, 'shadow': 'md', 'borderColor': '#E5E7EB', 'borderWidth': 0,
          },
          'overlay': {'color': '#000000', 'opacity': 0.5, 'dismissOnTap': true},
          'close': {'show': true, 'style': 'circle', 'color': '#FFFFFF', 'position': 'end'},
          'animation': 'zoom',
          'autoDismiss': 0,
          'dir': 'auto',
          ...design,
        },
      },
      'buttons': [
        {'id': 'copy', 'text': 'Copy SAVE20', 'action': 'dismiss', 'style': 'primary'},
      ],
    };

Widget _host(NexusInAppMessage m, {void Function(NexusInAppButton)? onButton, VoidCallback? onDismiss}) => MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          Positioned.fill(
            child: NexusInAppDesignedView(
              message: m,
              design: m.design!,
              onButton: onButton ?? (_) {},
              onDismiss: onDismiss ?? () {},
            ),
          ),
        ]),
      ),
    );

void main() {
  test('parses a designed message and keeps the legacy fields', () {
    final m = NexusInAppMessage.fromJson(_message());
    expect(m.title, 'Legacy title');
    final d = m.design!;
    expect(d.blocks.map((b) => b.id), ['bdg', 'h', 't', 's', 'd', 'b']);
    expect(d.frame.backgroundKind, 'gradient');
    expect(d.close.circle, isTrue);
    expect(d.overlayColor.a, closeTo(0.5, 0.01));
    final buttons = d.blocks.whereType<NexusInAppButtonsBlock>().single;
    expect(buttons.row, isTrue);
    expect(buttons.items.first.value, 'SAVE20');
  });

  test('a message from before the designer has no design', () {
    final m = NexusInAppMessage.fromJson({
      'id': 'old',
      'layout': 'modal',
      'content': {'title': 'Hi'},
    });
    expect(m.design, isNull);
  });

  test('auto direction follows the copy', () {
    final rtl = NexusInAppDesign.tryParse({
      'blocks': [
        {'id': 'h', 'type': 'heading', 'text': '٣٠٪ خصم'},
      ],
    })!;
    expect(rtl.resolveDirection(TextDirection.ltr), TextDirection.rtl);
    final ltr = NexusInAppDesign.tryParse({
      'blocks': [
        {'id': 'h', 'type': 'heading', 'text': '30% off'},
      ],
    })!;
    expect(ltr.resolveDirection(TextDirection.rtl), TextDirection.ltr);
  });

  for (final layout in ['modal', 'center', 'bottom_sheet', 'banner_top', 'banner_bottom', 'fullscreen']) {
    testWidgets('renders the $layout layout without overflow', (tester) async {
      final m = NexusInAppMessage.fromJson(_message(layout: layout));
      await tester.pumpWidget(_host(m));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Dark mode is here'), findsOneWidget);
      expect(find.text('Copy SAVE20'), findsOneWidget);
    });
  }

  testWidgets('a button reports its action, value included', (tester) async {
    NexusInAppButton? tapped;
    final m = NexusInAppMessage.fromJson(_message());
    await tester.pumpWidget(_host(m, onButton: (b) => tapped = b));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy SAVE20'));
    expect(tapped?.id, 'copy');
    expect(tapped?.action, 'copy');
    expect(tapped?.value, 'SAVE20');
  });

  testWidgets('backdrop tap dismisses only when the design allows it', (tester) async {
    var dismissed = 0;
    final m = NexusInAppMessage.fromJson(_message(design: {
      'overlay': {'color': '#000000', 'opacity': 0.5, 'dismissOnTap': false},
    }));
    await tester.pumpWidget(_host(m, onDismiss: () => dismissed++));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    expect(dismissed, 0);
    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(dismissed, 1);
  });

  testWidgets('auto-dismiss fires after the configured seconds', (tester) async {
    var dismissed = 0;
    final m = NexusInAppMessage.fromJson(_message(layout: 'banner_top', design: {'autoDismiss': 3}));
    await tester.pumpWidget(_host(m, onDismiss: () => dismissed++));
    await tester.pump(const Duration(seconds: 2));
    expect(dismissed, 0);
    await tester.pump(const Duration(seconds: 2));
    expect(dismissed, 1);
  });

  Map<String, Object?> carousel({int cards = 3, int autoplay = 0}) => _message(design: {
        'blocks': [
          {
            'id': 'car',
            'type': 'carousel',
            'aspect': '4:3',
            'peek': true,
            'autoplay': autoplay,
            'indicator': {'show': true, 'color': '#4F46E5'},
            'cards': [
              for (var i = 0; i < cards; i++)
                {
                  'id': 'card$i',
                  'title': 'Card $i',
                  'body': i.isEven ? 'Short' : 'A much longer description that wraps onto a few lines of text.',
                  'button': {'id': 'buy$i', 'text': 'Buy $i', 'action': 'url', 'url': 'myapp://p/$i', 'variant': 'filled', 'bg': '#4F46E5', 'fg': '#FFFFFF', 'radius': 10},
                  if (i == 1) 'tap': {'action': 'event', 'event': 'card_tapped'},
                },
            ],
          },
        ],
      });

  test('parses a carousel', () {
    final d = NexusInAppMessage.fromJson(carousel()).design!;
    final c = d.blocks.single as NexusInAppCarouselBlock;
    expect(c.cards.map((x) => x.id), ['card0', 'card1', 'card2']);
    expect(c.aspectRatio, closeTo(4 / 3, 0.001));
    expect(c.cards[1].tap?.event, 'card_tapped');
    expect(c.cards[2].button?.url, 'myapp://p/2');
  });

  testWidgets('ten cards render, all the same height, no overflow', (tester) async {
    final m = NexusInAppMessage.fromJson(carousel(cards: 10));
    await tester.pumpWidget(_host(m));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Buttons line up across short and long cards: same top edge.
    expect(tester.getTopLeft(find.text('Buy 0')).dy, tester.getTopLeft(find.text('Buy 1')).dy);
  });

  testWidgets('swiping snaps to the next card and moves the dots', (tester) async {
    NexusInAppButton? tapped;
    final m = NexusInAppMessage.fromJson(carousel());
    await tester.pumpWidget(_host(m, onButton: (b) => tapped = b));
    await tester.pumpAndSettle();
    final card0Start = tester.getTopLeft(find.text('Card 0')).dx;
    await tester.drag(find.text('Card 0'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    // Card 1 now sits exactly where card 0 started — snapped to the card boundary, not left at 120 px.
    expect(tester.getTopLeft(find.text('Card 1')).dx, closeTo(card0Start, 0.5));
    await tester.tap(find.text('Buy 1'));
    expect(tapped?.id, 'buy1');
    expect(tapped?.url, 'myapp://p/1');
    await tester.tap(find.text('Card 1'));
    expect(tapped?.id, 'card1'); // the card itself
    expect(tapped?.action, 'event');
  });

  testWidgets('autoplay advances and loops', (tester) async {
    final m = NexusInAppMessage.fromJson(carousel(cards: 2, autoplay: 2));
    await tester.pumpWidget(_host(m));
    await tester.pumpAndSettle();
    final start = tester.getTopLeft(find.text('Card 1')).dx;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Card 1')).dx, lessThan(start - 100));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Card 1')).dx, closeTo(start, 1)); // looped back
  });
}
