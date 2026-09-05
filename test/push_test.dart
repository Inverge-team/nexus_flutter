import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nexus_flutter/src/config.dart';
import 'package:nexus_flutter/src/http_client.dart';
import 'package:nexus_flutter/src/identity.dart';
import 'package:nexus_flutter/src/services/push_service.dart';

void main() {
  const cfg = NexusConfig(apiKey: 'k', baseUrl: 'https://api.test', appVersion: '1.2.3');
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('registerToken posts token + platform/provider + identity correlation', () async {
    final calls = <MapEntry<String, Map<String, dynamic>>>[];
    final client = MockClient((req) async {
      calls.add(MapEntry(req.url.path, jsonDecode(req.body) as Map<String, dynamic>));
      return http.Response('{}', 200);
    });
    final id = NexusIdentity()..distinctId = 'user_1';
    final push = NexusPush(NexusHttp(cfg, id, client: client), id, cfg);

    await push.registerToken('fcm_token_abcdef', platform: PushPlatform.android);

    expect(calls.single.key, '/partner/push/register');
    final body = calls.single.value;
    expect(body['token'], 'fcm_token_abcdef');
    expect(body['platform'], 'android');
    expect(body['provider'], 'fcm'); // default for android
    expect(body['distinctId'], 'user_1');
    expect(body['deviceKey'], id.deviceKey);
    expect(body['appVersion'], '1.2.3');
    expect(push.token, 'fcm_token_abcdef');
  });

  test('reportOpen attributes the open when data carries nexus_campaign_id', () async {
    final calls = <MapEntry<String, Map<String, dynamic>>>[];
    final client = MockClient((req) async {
      calls.add(MapEntry(req.url.path, jsonDecode(req.body) as Map<String, dynamic>));
      return http.Response('{}', 200);
    });
    final id = NexusIdentity();
    final push = NexusPush(NexusHttp(cfg, id, client: client), id, cfg);

    await push.registerToken('tok123456789', platform: PushPlatform.ios);
    await push.reportOpen({'nexus_campaign_id': 'camp_42', 'other': 'x'});

    final opened = calls.firstWhere((c) => c.key == '/partner/push/opened');
    expect(opened.value['campaignId'], 'camp_42');
    expect(opened.value['token'], 'tok123456789');
  });

  test('reportOpen is a no-op without a campaign id', () async {
    var opens = 0;
    final client = MockClient((req) async {
      if (req.url.path == '/partner/push/opened') opens++;
      return http.Response('{}', 200);
    });
    final id = NexusIdentity();
    final push = NexusPush(NexusHttp(cfg, id, client: client), id, cfg);
    await push.registerToken('tok123456789', platform: PushPlatform.web);
    await push.reportOpen({'foo': 'bar'});
    expect(opens, 0);
  });
}
