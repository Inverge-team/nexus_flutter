import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nexus_flutter/src/config.dart';
import 'package:nexus_flutter/src/http_client.dart';
import 'package:nexus_flutter/src/identity.dart';
import 'package:nexus_flutter/src/outbox.dart';
import 'package:nexus_flutter/src/services/errors_service.dart';

void main() {
  const cfg = NexusConfig(apiKey: 'k', baseUrl: 'https://api.test');

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('errors carry the app metadata block + structured stack', () async {
    Map<String, dynamic>? captured;
    final client = MockClient((req) async {
      captured = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('{}', 202);
    });

    final id = NexusIdentity()
      ..distinctId = 'user_1'
      ..appInfo = {
        'appName': 'Demo',
        'packageName': 'com.example.demo',
        'version': '1.2.3',
        'buildNumber': '45',
        'installerStore': 'com.android.vending',
        'installTime': 1700000000000,
        'updateTime': 1700500000000,
        'release': '1.2.3+45',
      };

    final outbox = NexusOutbox(NexusHttp(cfg, id, client: client), cfg);
    await outbox.init();
    final errors = NexusErrors(outbox, id, cfg);

    await errors.capture(StateError('boom'), StackTrace.current);
    for (var i = 0; i < 6 && outbox.pending > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await outbox.drain();
    }

    expect(captured, isNotNull);
    final app = (captured!['context'] as Map)['app'] as Map;
    expect(app['appName'], 'Demo');
    expect(app['packageName'], 'com.example.demo');
    expect(app['version'], '1.2.3');
    expect(app['buildNumber'], '45');
    expect(app['installerStore'], 'com.android.vending');
    expect(app['installTime'], 1700000000000);
    expect(app['updateTime'], 1700500000000);
    expect(captured!['release'], '1.2.3+45');
    expect((captured!['stack'] as List), isNotEmpty);
    // structured frames when parseable
    expect(captured!['stack'].first, anyOf(isA<Map>(), isA<String>()));
  });
}
