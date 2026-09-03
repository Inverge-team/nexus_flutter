import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nexus_flutter/src/config.dart';
import 'package:nexus_flutter/src/http_client.dart';
import 'package:nexus_flutter/src/identity.dart';
import 'package:nexus_flutter/src/outbox.dart';

void main() {
  const cfg = NexusConfig(apiKey: 'k', baseUrl: 'https://api.test');

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('retries a failing request until it is delivered', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return calls <= 2 ? http.Response('', 503) : http.Response('{}', 202);
    });
    final outbox = NexusOutbox(
      NexusHttp(cfg, NexusIdentity(), client: client),
      cfg,
    );
    await outbox.init();

    outbox.enqueue('/partner/events', {'events': <Object?>[]});
    for (var i = 0; i < 6 && outbox.pending > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await outbox.drain();
    }

    expect(outbox.pending, 0, reason: 'delivered after retries');
    expect(calls, greaterThanOrEqualTo(3), reason: 'two failures then success');
  });

  test('persists across restarts while offline', () async {
    // Always offline.
    final offline = MockClient((_) async => http.Response('', 503));
    final a = NexusOutbox(
      NexusHttp(cfg, NexusIdentity(), client: offline),
      cfg,
    );
    await a.init();
    a.enqueue('/partner/errors', {'message': 'boom'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(a.pending, 1);
    a.dispose();

    // A fresh instance loads the persisted item…
    final online = MockClient((_) async => http.Response('{}', 202));
    final b = NexusOutbox(NexusHttp(cfg, NexusIdentity(), client: online), cfg);
    await b.init();
    expect(b.pending, 1, reason: 'survived restart');
    for (var i = 0; i < 6 && b.pending > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await b.drain();
    }
    expect(b.pending, 0, reason: 'delivered once back online');
  });

  test('drops a poison item after maxAttempts', () async {
    final client = MockClient((_) async => http.Response('bad', 400));
    final outbox = NexusOutbox(
      NexusHttp(cfg, NexusIdentity(), client: client),
      cfg,
      maxAttempts: 3,
    );
    await outbox.init();
    outbox.enqueue('/partner/events', {'events': <Object?>[]});
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await outbox.drain();
    }
    expect(outbox.pending, 0, reason: 'given up after maxAttempts');
  });
}
