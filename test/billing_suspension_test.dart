import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_flutter/src/billing_suspension.dart';
import 'package:nexus_flutter/src/config.dart';
import 'package:nexus_flutter/src/http_client.dart';
import 'package:nexus_flutter/src/identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const cfg = NexusConfig(apiKey: 'k', baseUrl: 'https://api.test');
  final suspended = jsonEncode({
    'error': {
      'code': 'billing_suspended',
      'message': 'API access is suspended: USD 54.56 is past due on invoice INV-2026-10-0001.',
      'details': {'retryAfterSeconds': 120},
    },
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NexusBillingSuspension.instance.reset();
  });

  (NexusHttp, List<String>) make(List<http.Response> responses) {
    final calls = <String>[];
    final client = MockClient((req) async {
      calls.add(req.url.path);
      return responses.isEmpty ? http.Response('{}', 200) : responses.removeAt(0);
    });
    return (NexusHttp(cfg, NexusIdentity(), client: client), calls);
  }

  test('one 402 billing_suspended stops every further request', () async {
    final (h, calls) = make([http.Response(suspended, 402)]);
    expect(await h.post('/partner/errors', {'message': 'trip'}), isNull);
    for (var i = 0; i < 50; i++) {
      expect(await h.post('/partner/events', {'name': 'x'}), isNull);
      expect((await h.postRaw('/partner/push/register', {}))!.status, 402);
    }
    expect(calls, ['/partner/errors']);
    expect(h.suspended, isTrue);
  });

  test('the pause is persisted for the next launch', () async {
    final (h, _) = make([http.Response(suspended, 402)]);
    await h.post('/partner/errors', {'message': 'trip'});
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().any((k) => k.startsWith('nexus_billing_suspended_')), isTrue);
  });

  test('messaging is never held back; an empty wallet is not a suspension', () async {
    final (h, calls) = make([
      http.Response(jsonEncode({'error': {'code': 'insufficient_balance', 'message': 'Top up'}}), 402),
    ]);
    await h.post('/partner/events', {'name': 'x'});
    await h.post('/partner/events', {'name': 'y'});
    expect(calls.length, 2);
    expect(NexusBillingSuspension.isExempt('/partner/messaging/messages'), isTrue);
    expect(NexusBillingSuspension.isExempt('/partner/messagingx'), isFalse);
  });

  test('reset lets calls through again', () async {
    final (h, calls) = make([http.Response(suspended, 402)]);
    await h.post('/partner/errors', {'message': 'trip'});
    NexusBillingSuspension.instance.reset();
    await h.post('/partner/errors', {'message': 'after paying'});
    expect(calls.length, 2);
  });
}
