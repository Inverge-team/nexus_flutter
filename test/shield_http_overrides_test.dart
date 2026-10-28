import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nexus_flutter/nexus.dart';
import 'package:nexus_flutter/src/http_client.dart';
import 'package:nexus_flutter/src/identity.dart';
import 'package:nexus_flutter/src/shield/shield_http_overrides.dart';

/// A shield whose headers are predictable (the real one needs native keys).
class _FakeShield extends NexusShield {
  _FakeShield() : super(NexusHttp(const NexusConfig(apiKey: 'nxs_x_y'), NexusIdentity()), const NexusConfig(apiKey: 'nxs_x_y'));
  int calls = 0;

  @override
  Future<Map<String, String>> headers({required String method, required Uri url, List<int>? body}) async {
    calls++;
    return {'X-Nexus-Shield': 'tok', 'DPoP': 'proof:$method ${url.path}'};
  }
}

void main() {
  late HttpServer server;
  final seen = <String, Map<String, String?>>{};

  setUp(() async {
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      seen['${req.method} ${req.uri.path}'] = {
        'token': req.headers.value('x-nexus-shield'),
        'proof': req.headers.value('dpop'),
      };
      req.response
        ..statusCode = 200
        ..close();
    });
  });

  tearDown(() async {
    NexusShieldHttpOverrides.uninstall();
    await server.close(force: true);
  });

  test('signs Dio, package:http and HttpClient requests to listed hosts only', () async {
    final shield = _FakeShield();
    NexusShieldHttpOverrides.install(shield, ['127.0.0.1']);
    final port = server.port;

    await Dio().post('http://127.0.0.1:$port/dio', data: {'a': 1});
    await http.Client().get(Uri.parse('http://127.0.0.1:$port/pkg-http'));
    final c = HttpClient();
    await (await c.putUrl(Uri.parse('http://127.0.0.1:$port/raw'))).close();
    // Same server, different host name → NOT signed (third parties never get the token).
    await (await HttpClient().getUrl(Uri.parse('http://localhost:$port/other'))).close();
    // Nexus's own Shield calls are never signed by the hook.
    await (await HttpClient().postUrl(Uri.parse('http://127.0.0.1:$port/partner/shield/exchange'))).close();

    expect(seen['POST /dio'], {'token': 'tok', 'proof': 'proof:POST /dio'});
    expect(seen['GET /pkg-http'], {'token': 'tok', 'proof': 'proof:GET /pkg-http'});
    expect(seen['PUT /raw'], {'token': 'tok', 'proof': 'proof:PUT /raw'});
    expect(seen['GET /other'], {'token': null, 'proof': null});
    expect(seen['POST /partner/shield/exchange'], {'token': null, 'proof': null});
    expect(shield.calls, 3);
  });

  test('wildcards and chaining to an app-installed override', () async {
    final previous = _Marker();
    HttpOverrides.global = previous;
    NexusShieldHttpOverrides.install(_FakeShield(), ['*.example.com']);
    final o = HttpOverrides.current as NexusShieldHttpOverrides;
    expect(o.covers(Uri.parse('https://api.example.com/x')), isTrue);
    expect(o.covers(Uri.parse('https://example.com/x')), isTrue);
    expect(o.covers(Uri.parse('https://evil-example.com/x')), isFalse);
    o.createHttpClient(null);
    expect(previous.created, greaterThanOrEqualTo(1), reason: 'the app\'s own override still creates the client');
    NexusShieldHttpOverrides.uninstall();
    expect(identical(HttpOverrides.current, previous), isTrue);
    HttpOverrides.global = null;
  });
}

class _Marker extends HttpOverrides {
  int created = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created++;
    return super.createHttpClient(context);
  }
}
