import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_flutter/src/app_identity.dart';
import 'package:nexus_flutter/src/billing_suspension.dart';
import 'package:nexus_flutter/src/config.dart';
import 'package:nexus_flutter/src/http_client.dart';
import 'package:nexus_flutter/src/identity.dart';
import 'package:nexus_flutter/src/shield/shield_signing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// API keys restricted to attested apps answer `403 api_key_restricted`; the
/// SDK turns Shield signing on and retries once instead of failing silently.
void main() {
  const cfg = NexusConfig(apiKey: 'k', baseUrl: 'https://api.test');
  String restricted(String reason) => jsonEncode({
        'error': {
          'code': 'api_key_restricted',
          'message': 'This API key is restricted to specific apps',
          'details': {'restriction': 'apps', 'reason': reason},
        },
      });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NexusBillingSuspension.instance.reset();
  });

  test('restrictionReason reads only api_key_restricted 403s', () {
    expect(NexusShieldSigning.restrictionReason(403, jsonDecode(restricted('shield_token_required'))), 'shield_token_required');
    expect(NexusShieldSigning.restrictionReason(403, {'error': {'code': 'service_disabled'}}), isNull);
    expect(NexusShieldSigning.restrictionReason(401, jsonDecode(restricted('x'))), isNull);
    expect(NexusShieldSigning.restrictionReason(403, null), isNull);
  });

  (NexusHttp, List<String>) make(List<http.Response> responses) {
    final calls = <String>[];
    final client = MockClient((req) async {
      calls.add(req.url.path);
      return responses.isEmpty ? http.Response('{"ok":true}', 200) : responses.removeAt(0);
    });
    return (NexusHttp(cfg, NexusIdentity(), client: client), calls);
  }

  test('a restriction refusal is retried once when the hook says so', () async {
    final (h, calls) = make([http.Response(restricted('shield_token_required'), 403)]);
    final reasons = <String>[];
    h.onRestricted = (r) async {
      reasons.add(r);
      return true;
    };
    expect(await h.post('/partner/events', {'name': 'x'}), {'ok': true});
    expect(calls, ['/partner/events', '/partner/events']);
    expect(reasons, ['shield_token_required']);
  });

  test('no retry when the hook declines (another app / Shield off), and never loops', () async {
    final (h, calls) = make([
      http.Response(restricted('app_not_allowed'), 403),
      http.Response(restricted('shield_token_invalid'), 403),
      http.Response(restricted('shield_token_invalid'), 403),
    ]);
    h.onRestricted = (r) async => r != 'app_not_allowed';
    expect(await h.post('/partner/events', {}), isNull);
    expect(calls, ['/partner/events']);
    expect(await h.post('/partner/events', {}), isNull);
    expect(calls.length, 3); // one retry, then gives up
  });

  test('Shield bootstrap routes are never retried', () async {
    final (h, calls) = make([http.Response(restricted('shield_token_required'), 403)]);
    h.onRestricted = (_) async => true;
    await h.post('/partner/shield/challenge', {});
    expect(calls, ['/partner/shield/challenge']);
  });

  test('signing is off by default and outside the main isolate without persisted state', () async {
    expect(NexusShieldSigning.active, isFalse);
    expect(await NexusShieldSigning.headers('POST', Uri.parse('https://api.test/partner/events')), isEmpty);
    expect(await NexusShieldSigning.socketAuth('https://api.test'), isEmpty);
  });

  test('basic verification: the app names itself on every request (Google-style headers)', () async {
    await NexusAppIdentity.init({'osType': 'android', 'appId': 'com.acme.shop', 'signingCerts': ['ab' * 32]});
    final seen = <Map<String, String>>[];
    final h = NexusHttp(cfg, NexusIdentity(), client: MockClient((req) async {
      seen.add(req.headers);
      return http.Response('{}', 200);
    }));
    await h.post('/partner/events', {});
    expect(seen.single['X-Android-Package'], 'com.acme.shop');
    expect(seen.single['X-Android-Cert'], 'ab' * 32);
    expect(NexusAppIdentity.socketAuth(), {'androidPackage': 'com.acme.shop', 'androidCert': 'ab' * 32});

    await NexusAppIdentity.init({'osType': 'ios', 'appId': 'com.acme.shop'});
    expect(NexusAppIdentity.headers, {'X-Ios-Bundle-Identifier': 'com.acme.shop'});
    expect(await NexusAppIdentity.load(), {'X-Ios-Bundle-Identifier': 'com.acme.shop'});
  });
}
