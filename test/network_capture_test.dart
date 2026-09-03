@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_flutter/src/replay/network_capture.dart';

void main() {
  late HttpServer server;
  late String base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..write('ok');
      req.response.close();
    });
    base = 'http://${server.address.host}:${server.port}';
  });

  tearDown(() async {
    NexusNetworkCapture.uninstall();
    await server.close(force: true);
  });

  Future<void> hit(String path) async {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse('$base$path'));
    final resp = await req.close();
    await resp.drain<void>();
    client.close();
  }

  test(
    'captures a dart:io request (covers http + dio) via HttpOverrides',
    () async {
      final records = <Map<String, Object?>>[];
      NexusNetworkCapture.install(
        isRecording: () => true,
        ignore: (_) => false,
        record: ({
          required url,
          required method,
          required status,
          required durationMs,
          size,
        }) => records.add({'url': url, 'method': method, 'status': status}),
      );
      expect(NexusNetworkCapture.isActive, isTrue);

      await hit('/thing');

      expect(records.length, 1);
      expect(records.first['method'], 'GET');
      expect(records.first['status'], 200);
      expect((records.first['url'] as String).contains('/thing'), isTrue);
    },
  );

  test(
    'ignore predicate excludes matching requests (e.g. the Nexus API)',
    () async {
      final records = <Map<String, Object?>>[];
      NexusNetworkCapture.install(
        isRecording: () => true,
        ignore: (url) => url.path.startsWith('/partner'),
        record: ({
          required url,
          required method,
          required status,
          required durationMs,
          size,
        }) => records.add({'url': url}),
      );

      await hit('/partner/replay');
      await hit('/app/data');

      expect(records.length, 1);
      expect((records.first['url'] as String).contains('/app/data'), isTrue);
    },
  );

  test('records nothing while not recording', () async {
    final records = <Map<String, Object?>>[];
    NexusNetworkCapture.install(
      isRecording: () => false,
      ignore: (_) => false,
      record: ({
        required url,
        required method,
        required status,
        required durationMs,
        size,
      }) => records.add({'url': url}),
    );

    await hit('/thing');

    expect(records, isEmpty);
  });

  test('uninstall restores overrides and clears isActive', () {
    NexusNetworkCapture.install(
      isRecording: () => true,
      ignore: (_) => false,
      record: ({
        required url,
        required method,
        required status,
        required durationMs,
        size,
      }) {},
    );
    expect(NexusNetworkCapture.isActive, isTrue);
    NexusNetworkCapture.uninstall();
    expect(NexusNetworkCapture.isActive, isFalse);
  });
}
