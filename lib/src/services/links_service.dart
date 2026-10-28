import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../nexus_platform_interface.dart';
import '../config.dart';
import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';

/// Where a [NexusDeepLink] came from.
enum NexusDeepLinkSource {
  /// The first launch after an install, matched to the link that led to it
  /// (deferred deep link).
  install,

  /// The app was opened by a Nexus link while already installed.
  open,
}

/// A Nexus link that brought the user into the app, as the server resolved it.
class NexusDeepLink {
  const NexusDeepLink({
    required this.source,
    this.uri,
    this.path,
    this.params = const {},
    this.slug,
    this.campaign,
    this.mediaSource,
    this.channel,
    this.clickId,
    this.matchType,
  });

  final NexusDeepLinkSource source;

  /// The URL that opened the app. Null for a deferred match after an install.
  final Uri? uri;

  /// Where to take the user: the link's deep-link value (console), else the
  /// path of the URL that opened the app.
  final String? path;

  /// The link's deep-link parameters (console → link → deep-link params).
  final Map<String, dynamic> params;

  final String? slug;
  final String? campaign;
  final String? mediaSource;
  final String? channel;
  final String? clickId;

  /// `deterministic`, `probabilistic` or `organic`.
  final String? matchType;

  bool get isDeferred => source == NexusDeepLinkSource.install;

  @override
  String toString() => 'NexusDeepLink(${source.name}, path=$path, slug=$slug, match=$matchType)';
}

/// Deep linking & attribution (OneLink-style), automatic with `linksEnabled`:
///
/// - **Install** — reported once per install on first launch, matched to the
///   link click exactly via the Google Play install referrer on Android, or by
///   the opening link itself, else by the server's fingerprint window.
/// - **Open** — every launch or resume from a Nexus link is reported, matched
///   exactly by its click-id.
/// - **Routing** — when the app's router could not have seen the link (deferred
///   deep link after install; app opened by the short link itself via App Links /
///   Universal Links), the SDK routes to the link's deep-link value by delivering
///   it as a platform deep link — any Router or Navigator handles it.
///
/// Uninstalls are measured server-side (silent push probes); nothing runs here.
class NexusLinks {
  NexusLinks(this._http, this._id, [this._cfg]);

  final NexusHttp _http;
  final NexusIdentity _id;
  final NexusConfig? _cfg;

  static const _kInstallKey = 'nexus_links_install';

  /// Installs older than this when the SDK first runs are pre-existing installs
  /// (the app just added or upgraded the SDK), not new ones. Matches the
  /// server's install attribution window.
  static const _installWindow = Duration(days: 7);

  final _links = StreamController<NexusDeepLink>.broadcast();
  final Set<String> _seenClicks = {};
  NexusDeepLink? _pending;
  bool _started = false;

  /// Every Nexus deep link as it is resolved (install or open).
  Stream<NexusDeepLink> get onLink => _links.stream;

  /// The last deep link the SDK did NOT route itself (routing off, or the
  /// `onDeepLink` handler took over), cleared on read — e.g. route it from your
  /// home screen once the user has logged in.
  NexusDeepLink? consumePending() {
    final p = _pending;
    _pending = null;
    return p;
  }

  /// Wire automatic install/open reporting. Called by `Nexus.init` when
  /// `linksEnabled`; idempotent.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final platform = NexusPlatform.instance;
    // Live links first, then drain the cold-start queue: native switches to
    // live delivery the moment the queue is taken, so nothing falls between.
    platform.onLinkOpened((url) => unawaited(_handleUrl(url)));
    unawaited(platform.linksConfigure(_hosts.toList()));
    final pending = List<String>.of(await platform.linksTakePending());

    final install = await _newInstall();
    if (install != null) {
      // A link that launched the very first open IS the install's click.
      await _reportInstall(install, pending.isEmpty ? null : pending.removeAt(0));
    }
    for (final url in pending) {
      await _handleUrl(url);
    }
  }

  /// Report a conversion. Pass [clickId] (from the link) for deterministic
  /// attribution, or [slug] when the app was opened by the short link itself;
  /// otherwise the server matches by fingerprint. Returns the matched link's
  /// deep-link data (or null if unattributed).
  Future<Map<String, dynamic>?> attribute({
    String type = 'install',
    String? clickId,
    String? slug,
    String? name,
    String? platform,
    Map<String, Object?>? properties,
  }) async {
    final res = await _attributeRaw(
      type: type,
      clickId: clickId,
      slug: slug,
      name: name,
      platform: platform,
      properties: properties,
    );
    return res?['link'] as Map<String, dynamic>?;
  }

  /// Convenience: parse a deep-link [uri] for `link_click_id` and attribute an
  /// open, returning the deep-link data. Not needed with `linksEnabled`, which
  /// reports opens automatically.
  Future<Map<String, dynamic>?> handleDeepLink(
    Uri uri, {
    String type = 'open',
  }) {
    final clickId = uri.queryParameters['link_click_id'];
    if (clickId != null) _seenClicks.add(clickId);
    return attribute(type: type, clickId: clickId, slug: _shortLinkSlug(uri));
  }

  // ── automatic flow ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _attributeRaw({
    required String type,
    String? clickId,
    String? slug,
    String? name,
    String? platform,
    Map<String, Object?>? properties,
  }) async {
    final res = await _http.post('/partner/links/attribute', {
      'type': type,
      'clickId': ?clickId,
      'slug': ?slug,
      'name': ?name,
      'platform': platform ?? _id.deviceContext['osType'],
      if (_id.distinctId != null) 'distinctId': _id.distinctId,
      'deviceId': _id.deviceKey,
      'sessionKey': _id.sessionKey,
      'properties': ?properties,
    });
    if (res == null) return null;
    final data = res['data'] ?? res;
    return data is Map<String, dynamic> ? data : null;
  }

  /// Hosts serving this tenant's short links: the API host plus branded ones.
  Set<String> get _hosts {
    final cfg = _cfg;
    final hosts = <String>{};
    if (cfg != null) {
      hosts.add(Uri.tryParse(cfg.httpBase)?.host.toLowerCase() ?? '');
      for (final d in cfg.linkDomains) {
        final h = d.contains('://') ? Uri.tryParse(d)?.host : d.split('/').first;
        hosts.add((h ?? '').toLowerCase());
      }
    }
    return hosts..remove('');
  }

  /// `/l/<slug>` or `/a/<appId>/<slug>` on a Nexus link host, else null.
  String? _shortLinkSlug(Uri? uri) {
    if (uri == null || !_hosts.contains(uri.host.toLowerCase())) return null;
    final s = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    if (s.length == 2 && s[0] == 'l') return s[1];
    if (s.length == 3 && s[0] == 'a') return s[2];
    return null;
  }

  /// Non-null on the first launch of a new install (or reinstall).
  Future<_InstallMark?> _newInstall() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final installedAt = _id.appInfo['installTime'];
      // The OS install timestamp changes on every (re)install, which catches a
      // reinstall even when Android Auto Backup restored our preferences.
      final stamp = '${installedAt ?? 'unknown'}';
      final previous = prefs.getString(_kInstallKey);
      if (previous == stamp) return null;
      if (previous == null &&
          installedAt is int &&
          DateTime.now().millisecondsSinceEpoch - installedAt > _installWindow.inMilliseconds) {
        await prefs.setString(_kInstallKey, stamp); // pre-existing install
        return null;
      }
      return _InstallMark(prefs, stamp, reinstall: previous != null);
    } catch (e) {
      NexusLog.debug('links: install check skipped — $e');
      return null;
    }
  }

  Future<void> _reportInstall(_InstallMark install, String? openingUrl) async {
    final opening = openingUrl == null ? null : Uri.tryParse(openingUrl);
    final slug = _shortLinkSlug(opening);
    var clickId = opening?.queryParameters['link_click_id'];
    if (clickId == null && slug == null) clickId = await _referrerClickId();
    if (clickId != null) _seenClicks.add(clickId);

    final res = await _attributeRaw(
      type: 'install',
      clickId: clickId,
      slug: slug,
      properties: install.reinstall ? {'reinstall': true} : null,
    );
    if (res == null) return; // network/server failure — retried next launch
    await install.markReported();
    NexusLog.info('links: install reported (${res['matchType'] ?? 'organic'})');

    final link = _toDeepLink(res, NexusDeepLinkSource.install, opening, slug);
    // The router saw a plain deep link (custom scheme) itself; it never sees a
    // short link (consumed natively) or a deferred match (no URL at all).
    if (link != null) await _deliver(link, routable: opening == null || slug != null);
  }

  Future<void> _handleUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final slug = _shortLinkSlug(uri);
    final clickId = uri.queryParameters['link_click_id'];
    if (slug == null && clickId == null) return; // not a Nexus link
    if (clickId != null && !_seenClicks.add(clickId)) return; // already reported

    final res = await _attributeRaw(type: 'open', clickId: clickId, slug: slug);
    final link = _toDeepLink(res, NexusDeepLinkSource.open, uri, slug);
    if (link != null) await _deliver(link, routable: slug != null);
  }

  NexusDeepLink? _toDeepLink(
    Map<String, dynamic>? res,
    NexusDeepLinkSource source,
    Uri? uri,
    String? slug,
  ) {
    final link = res?['link'] as Map<String, dynamic>?;
    if (link == null && (uri == null || slug != null)) return null; // nothing to open
    final value = link?['deepLinkValue'] as String?;
    return NexusDeepLink(
      source: source,
      uri: uri,
      path: _routeFor(value) ?? (slug == null && uri != null ? _routeFor(uri.toString()) : null),
      params: (link?['deepLinkParams'] as Map?)?.cast<String, dynamic>() ?? const {},
      slug: link?['slug'] as String? ?? slug,
      campaign: link?['campaign'] as String?,
      mediaSource: link?['mediaSource'] as String?,
      channel: link?['channel'] as String?,
      clickId: res?['clickId'] as String?,
      matchType: res?['matchType'] as String?,
    );
  }

  /// A deep-link value as a router location: `/orders/42` stays as is; a full
  /// URL (`myapp:///orders/42`, `https://…/orders/42`) becomes its path + query.
  static String? _routeFor(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final v = value.trim();
    final uri = Uri.tryParse(v);
    if (uri == null || !uri.hasScheme) return v.startsWith('/') ? v : '/$v';
    final path = uri.path.isEmpty ? '/' : uri.path;
    return uri.hasQuery ? '$path?${uri.query}' : path;
  }

  Future<void> _deliver(NexusDeepLink link, {required bool routable}) async {
    NexusLog.info('links: $link');
    _links.add(link);
    var handled = false;
    final handler = _cfg?.onDeepLink;
    if (handler != null) {
      try {
        handled = await handler(link);
      } catch (e) {
        NexusLog.warn('links: onDeepLink threw — $e');
      }
    }
    if (!routable || link.path == null) return;
    if (handled || !(_cfg?.autoRouteDeepLinks ?? false)) {
      _pending = link;
      return;
    }
    await _route(link.path!);
  }

  /// Hand [location] to the app exactly as the OS would deliver a deep link:
  /// a `pushRouteInformation` message on the navigation channel, which every
  /// Router (go_router, auto_route, …) and a plain Navigator already handle.
  Future<void> _route(String location) async {
    try {
      final binding = WidgetsFlutterBinding.ensureInitialized();
      // Before runApp there is no router to receive it yet: wait for the first
      // frame. Once the app is up, deliver immediately.
      if (binding.rootElement == null) await binding.waitUntilFirstFrameRasterized;
      final data = SystemChannels.navigation.codec.encodeMethodCall(
        MethodCall('pushRouteInformation', {'location': location, 'state': null}),
      );
      ui.channelBuffers.push(SystemChannels.navigation.name, data, (_) {});
      NexusLog.debug('links: routed → $location');
    } catch (e) {
      NexusLog.warn('links: could not route to $location — $e');
    }
  }

  /// Android: the Play install referrer's click-id (null elsewhere / on timeout).
  Future<String?> _referrerClickId() async {
    try {
      final referrer = await NexusPlatform.instance
          .installReferrer()
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      if (referrer == null || referrer.isEmpty) return null;
      return Uri.splitQueryString(referrer)['link_click_id'];
    } catch (_) {
      return null;
    }
  }

  void dispose() => _links.close();
}

class _InstallMark {
  _InstallMark(this._prefs, this._stamp, {required this.reinstall});

  final SharedPreferences _prefs;
  final String _stamp;
  final bool reinstall;

  Future<void> markReported() => _prefs.setString(NexusLinks._kInstallKey, _stamp);
}
