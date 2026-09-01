import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_flutter/src/config.dart';
import 'package:nexus_flutter/src/replay/replay_controller.dart';
import 'package:nexus_flutter/src/replay/replay_mask.dart';

void main() {
  testWidgets('captures a frame → emits meta + full snapshot with a PNG data URI',
      (tester) async {
    final events = <Map<String, Object?>>[];
    const cfg = NexusConfig(apiKey: 'k', replayEnabled: true, replayPixelRatio: 1.0);
    final controller = NexusReplayController(cfg, events.add);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: controller.repaintBoundaryKey,
          child: Container(width: 100, height: 200, color: const Color(0xFFFF0000)),
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
  });

  testWidgets('identical consecutive frames are de-duplicated', (tester) async {
    final events = <Map<String, Object?>>[];
    const cfg = NexusConfig(apiKey: 'k', replayEnabled: true, replayPixelRatio: 1.0);
    final controller = NexusReplayController(cfg, events.add);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: controller.repaintBoundaryKey,
          child: Container(width: 50, height: 50, color: const Color(0xFF00FF00)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.runAsync(() => controller.captureFrameForTest());
    final afterFirst = events.length;
    await tester.runAsync(() => controller.captureFrameForTest());

    expect(events.length, afterFirst, reason: 'unchanged screen emits no new frame');
    controller.dispose();
  });

  testWidgets('auto-masks text fields when replayMaskTextFields is on', (tester) async {
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
                  child: TextField(controller: TextEditingController(text: 'SECRET-1234')),
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
    expect(masked == unmasked, isFalse, reason: 'redacting the text field must change the frame');
  });

  testWidgets('NexusMask registers while mounted and cleans up', (tester) async {
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
