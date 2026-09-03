import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_flutter/src/config.dart';
import 'package:nexus_flutter/src/replay/replay_controller.dart';
import 'package:nexus_flutter/src/replay/replay_mask.dart';

void main() {
  testWidgets(
    'captures a frame → emits meta + full snapshot with a PNG data URI',
    (tester) async {
      final events = <Map<String, Object?>>[];
      const cfg = NexusConfig(
        apiKey: 'k',
        replayEnabled: true,
        replayPixelRatio: 1.0,
      );
      final controller = NexusReplayController(cfg, events.add);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: controller.repaintBoundaryKey,
            child: Container(
              width: 100,
              height: 200,
              color: const Color(0xFFFF0000),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() => controller.captureFrameForTest());

      expect(events.any((e) => e['type'] == 4), isTrue, reason: 'meta event');
      final full = events.firstWhere((e) => e['type'] == 2, orElse: () => {});
      expect(full, isNotEmpty, reason: 'full snapshot event');

      final node = (full['data'] as Map)['node'] as Map;
      final html = (node['childNodes'] as List)[1] as Map;
      final body = (html['childNodes'] as List)[1] as Map;
      final img = (body['childNodes'] as List)[0] as Map;
      final src = (img['attributes'] as Map)['src'] as String;
      expect(src.startsWith('data:image/png;base64,'), isTrue);
      expect(src.length, greaterThan('data:image/png;base64,'.length + 10));

      controller.dispose();
    },
  );

  testWidgets('identical consecutive frames are de-duplicated', (tester) async {
    final events = <Map<String, Object?>>[];
    const cfg = NexusConfig(
      apiKey: 'k',
      replayEnabled: true,
      replayPixelRatio: 1.0,
    );
    final controller = NexusReplayController(cfg, events.add);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: controller.repaintBoundaryKey,
          child: Container(
            width: 50,
            height: 50,
            color: const Color(0xFF00FF00),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.runAsync(() => controller.captureFrameForTest());
    final afterFirst = events.length;
    await tester.runAsync(() => controller.captureFrameForTest());

    expect(
      events.length,
      afterFirst,
      reason: 'unchanged screen emits no new frame',
    );
    controller.dispose();
  });

  testWidgets('auto-masks text fields when replayMaskTextFields is on', (
    tester,
  ) async {
    Future<String> captureImg({required bool mask}) async {
      final events = <Map<String, Object?>>[];
      final cfg = NexusConfig(
        apiKey: 'k',
        replayEnabled: true,
        replayPixelRatio: 1.0,
        replayMaskTextFields: mask,
      );
      final controller = NexusReplayController(cfg, events.add);
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: controller.repaintBoundaryKey,
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 200,
                  child: TextField(
                    controller: TextEditingController(text: 'SECRET-1234'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => controller.captureFrameForTest());
      controller.dispose();
      final full = events.firstWhere((e) => e['type'] == 2);
      final node = (full['data'] as Map)['node'] as Map;
      final html = (node['childNodes'] as List)[1] as Map;
      final body = (html['childNodes'] as List)[1] as Map;
      final img = (body['childNodes'] as List)[0] as Map;
      return (img['attributes'] as Map)['src'] as String;
    }

    final masked = await captureImg(mask: true);
    final unmasked = await captureImg(mask: false);
    expect(
      masked == unmasked,
      isFalse,
      reason: 'redacting the text field must change the frame',
    );
  });

  testWidgets('emits page (meta), click, and network context events', (
    tester,
  ) async {
    final events = <Map<String, Object?>>[];
    const cfg = NexusConfig(
      apiKey: 'k',
      replayEnabled: true,
      replayPixelRatio: 1.0,
      replayCaptureConsole: false,
    );
    final controller = NexusReplayController(cfg, events.add);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: controller.repaintBoundaryKey,
          child: Container(
            width: 80,
            height: 80,
            color: const Color(0xFF123456),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => controller.captureFrameForTest(),
    ); // records + sizes

    controller.trackScreen('/orders/42');
    controller.onPointerDown(const Offset(10, 10));
    controller.onPointerUp(const Offset(10, 10));
    controller.recordNetwork(
      url: 'https://api/x',
      method: 'GET',
      status: 200,
      durationMs: 12,
    );

    final metas = events.where((e) => e['type'] == 4).toList();
    expect(
      metas.length,
      greaterThanOrEqualTo(2),
      reason: 'first-frame meta + page meta',
    );
    expect((metas.last['data'] as Map)['href'], 'app:///orders/42');

    final click = events.any(
      (e) =>
          e['type'] == 3 &&
          (e['data'] as Map)['source'] == 2 &&
          (e['data'] as Map)['type'] == 2,
    );
    expect(click, isTrue, reason: 'tap emits a MouseInteraction Click');

    final net = events.firstWhere(
      (e) =>
          e['type'] == 6 && (e['data'] as Map)['plugin'] == 'rrweb/network@1',
      orElse: () => {},
    );
    expect(net, isNotEmpty);

    controller.dispose();
  });

  testWidgets('observeRouter emits page metas on navigation and de-dupes', (
    tester,
  ) async {
    final events = <Map<String, Object?>>[];
    const cfg = NexusConfig(
      apiKey: 'k',
      replayEnabled: true,
      replayPixelRatio: 1.0,
      replayCaptureConsole: false,
      replayCaptureNetwork: false,
    );
    final controller = NexusReplayController(cfg, events.add);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: controller.repaintBoundaryKey,
          child: Container(
            width: 60,
            height: 60,
            color: const Color(0xFF010203),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => controller.captureFrameForTest(),
    ); // sentFirst + size

    var path = '/home';
    final router = ValueNotifier<int>(0); // stand-in for a router delegate
    controller.observeRouter(router, () => path); // seeds '/home'

    path = '/orders/42';
    router.value = 1; // notify → track '/orders/42'
    path = '/orders/42';
    router.value = 2; // same path → de-duped

    final orderMetas = events
        .where(
          (e) =>
              e['type'] == 4 &&
              (e['data'] as Map)['href'].toString().contains('orders'),
        )
        .toList();
    expect(orderMetas.length, 1, reason: 'one meta per distinct route');
    expect((orderMetas.first['data'] as Map)['href'], 'app:///orders/42');

    controller.dispose();
  });

  testWidgets('tees debugPrint into console events while recording', (
    tester,
  ) async {
    final events = <Map<String, Object?>>[];
    const cfg = NexusConfig(
      apiKey: 'k',
      replayEnabled: true,
      replayCaptureConsole: true,
    );
    final controller = NexusReplayController(cfg, events.add);

    controller.start();
    debugPrint('hello from app');
    debugPrint('[Nexus] internal log'); // must be skipped (no feedback loop)
    controller.stop();

    final consoles = events
        .where(
          (e) =>
              e['type'] == 6 &&
              (e['data'] as Map)['plugin'] == 'rrweb/console@1',
        )
        .toList();
    expect(consoles.length, 1);
    final payload =
        ((consoles.first['data'] as Map)['payload'] as Map)['payload'] as List;
    expect(payload.first.toString().contains('hello from app'), isTrue);
  });

  testWidgets('NexusMask registers while mounted and cleans up', (
    tester,
  ) async {
    expect(NexusMaskRegistry.instance.isEmpty, isTrue);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: NexusMask(child: SizedBox(width: 10, height: 10)),
      ),
    );
    expect(NexusMaskRegistry.instance.isEmpty, isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(NexusMaskRegistry.instance.isEmpty, isTrue);
  });
}
