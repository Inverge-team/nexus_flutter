import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nexus_flutter/nexus_platform_interface.dart';
import 'package:nexus_flutter/src/config.dart';
import 'package:nexus_flutter/src/http_client.dart';
import 'package:nexus_flutter/src/identity.dart';
import 'package:nexus_flutter/src/services/links_service.dart';

class _FakePlatform extends NexusPlatform with MockPlatformInterfaceMixin {
  _FakePlatform({this.pending = const [], this.referrer});

  final List<String> pending;
  final String? referrer;
  void Function(String url)? sink;
  List<String>? configuredHosts;

  @override
  Future<List<String>> linksTakePending() async => List.of(pending);

  @override
  void onLinkOpened(void Function(String url) s) => sink = s;

  @override
  Future<void> linksConfigure(List<String> hosts) async => configuredHosts = hosts;

  @override
  Future<String?> installReferrer() async => referrer;
}

/// Records what the SDK delivers on the navigation channel, the way the app's
/// router would receive an OS deep link.
class _RouteSpy with WidgetsBindingObserver {
  final routes = <String>[];

  @override
  Future<bool> didPushRouteInformation(RouteInformation info) async {
    routes.add(info.uri.toString());
    return true;
  }
}

typedef _Call = MapEntry<String, Map<String, dynamic>>;

const _link = {
  'slug': 'promo',
  'deepLinkValue': '/app/orders/42',
  'deepLinkParams': {'ref': 'sms'},
  'campaign': 'fall',
  'mediaSource': 'sms',
  'channel': null,
};

void main() {
  // One install = one OS install timestamp, stable across launches.
  final now = DateTime.now();
  late List<_Call> calls;
  late _RouteSpy spy;

  NexusLinks build({
    required NexusPlatform platform,
    int? installedDaysAgo = 0,
    NexusConfig cfg = const NexusConfig(apiKey: 'k', baseUrl: 'https://api.test'),
    bool matched = true,
  }) {
    NexusPlatform.instance = platform;
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      calls.add(_Call(req.url.path, body));
      return http.Response(
        jsonEncode({
          'matched': matched,
          'matchType': body['clickId'] != null || body['slug'] != null ? 'deterministic' : 'organic',
          'clickId': body['clickId'] ?? 'srv_click',
          'link': matched ? _link : null,
        }),
        200,
      );
    });
    final id = NexusIdentity()..deviceContext = {'osType': 'android'};
    if (installedDaysAgo != null) {
      id.appInfo = {
        'installTime': now.subtract(Duration(days: installedDaysAgo)).millisecondsSinceEpoch,
      };
    }
    return NexusLinks(NexusHttp(cfg, id, client: client), id, cfg);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    spy = _RouteSpy();
  });

  Future<void> startAndSettle(WidgetTester tester, NexusLinks links) async {
    WidgetsBinding.instance.addObserver(spy);
    addTearDown(() => WidgetsBinding.instance.removeObserver(spy));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(links.start);
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('first launch reports the install with the Play referrer click and routes the deferred link', (tester) async {
    final platform = _FakePlatform(referrer: 'link_click_id=play_click&utm_source=sms');
    final links = build(platform: platform);
    await startAndSettle(tester, links);

    final install = calls.single;
    expect(install.key, '/partner/links/attribute');
    expect(install.value['type'], 'install');
    expect(install.value['clickId'], 'play_click');
    expect(install.value['platform'], 'android');
    expect(spy.routes, ['/app/orders/42'], reason: 'deferred deep link routed like an OS deep link');
    expect(platform.configuredHosts, ['api.test']);

    // Same install, next launch: nothing to report.
    calls.clear();
    final again = build(platform: _FakePlatform());
    await tester.runAsync(again.start);
    expect(calls, isEmpty);
  });

  testWidgets('an install older than the attribution window is not reported', (tester) async {
    final links = build(platform: _FakePlatform(), installedDaysAgo: 30);
    await startAndSettle(tester, links);
    expect(calls, isEmpty, reason: 'the app merely added/upgraded the SDK');
  });

  testWidgets('opened by the short link itself: open reported by slug and routed', (tester) async {
    // Install already reported (no OS install time on this device → stamp "unknown").
    SharedPreferences.setMockInitialValues({'nexus_links_install': 'unknown'});
    final links = build(platform: _FakePlatform(pending: ['https://api.test/a/com.tenant.a/promo']), installedDaysAgo: null);
    await startAndSettle(tester, links);

    final open = calls.single.value;
    expect(open['type'], 'open');
    expect(open['slug'], 'promo');
    expect(open.containsKey('clickId'), isFalse);
    expect(spy.routes, ['/app/orders/42'], reason: 'the router never saw /a/…/promo');
  });

  testWidgets('a custom-scheme link with a click id is reported once and left to the router', (tester) async {
    SharedPreferences.setMockInitialValues({'nexus_links_install': 'unknown'});
    final platform = _FakePlatform(pending: ['tenant:///app/orders/42?link_click_id=c1']);
    final links = build(platform: platform, installedDaysAgo: null);
    await startAndSettle(tester, links);
    await tester.runAsync(() async => platform.sink!('tenant:///app/orders/42?link_click_id=c1')); // duplicate

    expect(calls.length, 1);
    expect(calls.single.value['type'], 'open');
    expect(calls.single.value['clickId'], 'c1');
    expect(spy.routes, isEmpty, reason: 'Flutter already routed this path itself');
  });

  testWidgets('a non-Nexus link is ignored', (tester) async {
    SharedPreferences.setMockInitialValues({'nexus_links_install': 'unknown'});
    final links = build(platform: _FakePlatform(pending: ['tenant:///settings']), installedDaysAgo: null);
    await startAndSettle(tester, links);
    expect(calls, isEmpty);
  });

  testWidgets('onDeepLink can take over; the link waits in consumePending', (tester) async {
    NexusDeepLink? seen;
    final cfg = NexusConfig(
      apiKey: 'k',
      baseUrl: 'https://api.test',
      onDeepLink: (link) {
        seen = link;
        return true;
      },
    );
    final links = build(platform: _FakePlatform(), cfg: cfg);
    await startAndSettle(tester, links);

    expect(seen?.isDeferred, isTrue);
    expect(seen?.params, {'ref': 'sms'});
    expect(spy.routes, isEmpty);
    expect(links.consumePending()?.path, '/app/orders/42');
    expect(links.consumePending(), isNull, reason: 'cleared on read');
  });
}
