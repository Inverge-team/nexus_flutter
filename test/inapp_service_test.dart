import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nexus_flutter/src/config.dart';
import 'package:nexus_flutter/src/http_client.dart';
import 'package:nexus_flutter/src/identity.dart';
import 'package:nexus_flutter/src/inapp/inapp_models.dart';
import 'package:nexus_flutter/src/services/inapp_service.dart';

/// A fake `/partner/inapp` backend: answers `active` with [messages], records every call.
({NexusInApp inApp, List<MapEntry<String, Map<String, dynamic>>> calls}) _setup(
  List<Map<String, Object?>> messages, {
  NexusIdentity? identity,
}) {
  const cfg = NexusConfig(apiKey: 'k', baseUrl: 'https://api.test', appVersion: '2.4.1');
  final id = identity ?? NexusIdentity();
  final calls = <MapEntry<String, Map<String, dynamic>>>[];
  final client = MockClient((req) async {
    calls.add(MapEntry(req.url.path, jsonDecode(req.body) as Map<String, dynamic>));
    if (req.url.path.endsWith('/active')) return http.Response(jsonEncode({'messages': messages, 'testDevice': false}), 200);
    return http.Response('{"ok":true}', 202);
  });
  return (inApp: NexusInApp(NexusHttp(cfg, id, client: client), id, cfg), calls: calls);
}

Map<String, Object?> _msg(String id, {String? variantId, bool test = false}) => {
      'id': id,
      'layout': 'modal',
      'content': {'title': 'Hi'},
      'trigger': null,
      'variantId': ?variantId,
      if (test) 'test': true,
    };

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('fetch sends who this is, for targeting and {{variables}}', () async {
    final id = NexusIdentity()
      ..distinctId = 'u_1'
      ..name = 'Sara Ahmed'
      ..email = 's@x.io'
      ..deviceContext = {'osType': 'Android', 'osVersion': '14'};
    id.traits['plan'] = 'pro';
    final s = _setup([], identity: id);
    await s.inApp.setProperties({'coupon': 'SARA20', 'when': DateTime(2026)}, refetch: false);
    await s.inApp.fetch();
    final body = s.calls.single.value;
    expect(body['distinctId'], 'u_1');
    expect(body['properties'], containsPair('plan', 'pro'));
    expect(body['properties'], containsPair('name', 'Sara Ahmed'));
    expect(body['properties'], containsPair('coupon', 'SARA20'));
    expect(body['properties']['when'], isA<String>()); // non-JSON values are stringified
    expect(body['context'], containsPair('platform', 'android'));
    expect(body['context'], containsPair('appVersion', '2.4.1'));
  });

  test('impressions and clicks carry the variant and the install', () async {
    final s = _setup([_msg('m1', variantId: 'B')]);
    await s.inApp.fetch();
    final m = s.inApp.current.value!;
    expect(m.variantId, 'B');
    s.inApp.tapButton(m, const NexusInAppButton(id: 'b1', text: 'Go', action: 'dismiss'));
    await Future<void>.delayed(Duration.zero);
    final events = s.calls.where((c) => c.key.endsWith('/event')).map((c) => c.value).toList();
    expect(events.map((e) => e['type']), ['impression', 'click']);
    expect(events.every((e) => e['variantId'] == 'B' && (e['deviceKey'] as String).startsWith('dev_')), isTrue);
  });

  test('a console test shows at once, ahead of everything, and reports nothing', () async {
    final s = _setup([_msg('m1'), _msg('test_abc', test: true)]);
    await s.inApp.fetch();
    final shown = s.inApp.current.value!;
    expect(shown.id, 'test_abc');
    expect(shown.isTest, isTrue);
    expect(s.inApp.active.map((m) => m.id), ['m1']); // tests never join the trigger list
    s.inApp.dismiss(shown);
    await Future<void>.delayed(Duration.zero);
    expect(s.calls.where((c) => c.key.endsWith('/event')), isEmpty);
  });
}
