import 'dart:async';
import 'dart:io';

import '../logging.dart';
import 'shield_service.dart';

/// Signs every `dart:io` HTTP request to the configured hosts with Shield
/// headers — so apps protect their API with ONE config line
/// (`NexusConfig.shieldHosts`) instead of wiring an interceptor into each
/// client. Dio (default adapter), `package:http` and raw [HttpClient] all
/// create their sockets through [HttpOverrides], which is where this hooks in.
///
/// Chains to any [HttpOverrides] the app installed before `Nexus.init` (e.g.
/// certificate pinning), so it never replaces the app's own behaviour. Clients
/// that bypass `dart:io` (Cronet / `native_dio_adapter`, web) aren't covered —
/// use `NexusShieldDioInterceptor` / `NexusShieldClient` there.
class NexusShieldHttpOverrides extends HttpOverrides {
  NexusShieldHttpOverrides(this._shield, List<String> hosts, this._previous)
      : _matchers = hosts.map(_hostMatcher).toList();

  final NexusShield _shield;
  final HttpOverrides? _previous;
  final List<bool Function(String host)> _matchers;

  /// Install as the global override (once; re-init replaces it).
  static void install(NexusShield shield, List<String> hosts) {
    final current = HttpOverrides.current;
    final previous = current is NexusShieldHttpOverrides ? current._previous : current;
    HttpOverrides.global = NexusShieldHttpOverrides(shield, hosts, previous);
    NexusLog.info('shield: signing requests to ${hosts.join(', ')}');
  }

  /// Remove our hook, restoring whatever the app had before.
  static void uninstall() {
    final current = HttpOverrides.current;
    if (current is NexusShieldHttpOverrides) HttpOverrides.global = current._previous;
  }

  bool covers(Uri url) => !url.path.startsWith('/partner/shield') && _matchers.any((m) => m(url.host));

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = _previous?.createHttpClient(context) ?? super.createHttpClient(context);
    return _ShieldHttpClient(inner, this);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      _previous?.findProxyFromEnvironment(url, environment) ?? super.findProxyFromEnvironment(url, environment);

  /// `api.example.com` matches exactly; `*.example.com` matches any subdomain
  /// (and the apex). Case-insensitive.
  static bool Function(String) _hostMatcher(String pattern) {
    final p = pattern.trim().toLowerCase();
    if (p.startsWith('*.')) {
      final apex = p.substring(2);
      return (h) {
        final host = h.toLowerCase();
        return host == apex || host.endsWith('.$apex');
      };
    }
    return (h) => h.toLowerCase() == p;
  }

  Future<HttpClientRequest> sign(Future<HttpClientRequest> pending) async {
    final request = await pending;
    if (!covers(request.uri)) return request;
    try {
      final headers = await _shield.headers(method: request.method, url: request.uri);
      headers.forEach(request.headers.set);
    } catch (e) {
      NexusLog.warn('shield: request left unsigned ($e)');
    }
    return request;
  }
}

/// Delegates everything to the real client; only request creation is wrapped.
class _ShieldHttpClient implements HttpClient {
  _ShieldHttpClient(this._inner, this._o);

  final HttpClient _inner;
  final NexusShieldHttpOverrides _o;

  // ---- request creation (signed) ----------------------------------------------
  @override
  Future<HttpClientRequest> open(String method, String host, int port, String path) => _o.sign(_inner.open(method, host, port, path));
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => _o.sign(_inner.openUrl(method, url));
  @override
  Future<HttpClientRequest> get(String host, int port, String path) => _o.sign(_inner.get(host, port, path));
  @override
  Future<HttpClientRequest> getUrl(Uri url) => _o.sign(_inner.getUrl(url));
  @override
  Future<HttpClientRequest> post(String host, int port, String path) => _o.sign(_inner.post(host, port, path));
  @override
  Future<HttpClientRequest> postUrl(Uri url) => _o.sign(_inner.postUrl(url));
  @override
  Future<HttpClientRequest> put(String host, int port, String path) => _o.sign(_inner.put(host, port, path));
  @override
  Future<HttpClientRequest> putUrl(Uri url) => _o.sign(_inner.putUrl(url));
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) => _o.sign(_inner.delete(host, port, path));
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => _o.sign(_inner.deleteUrl(url));
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) => _o.sign(_inner.patch(host, port, path));
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => _o.sign(_inner.patchUrl(url));
  @override
  Future<HttpClientRequest> head(String host, int port, String path) => _o.sign(_inner.head(host, port, path));
  @override
  Future<HttpClientRequest> headUrl(Uri url) => _o.sign(_inner.headUrl(url));

  // ---- plain delegation -------------------------------------------------------
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool v) => _inner.autoUncompress = v;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? v) => _inner.connectionTimeout = v;
  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration v) => _inner.idleTimeout = v;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) => _inner.maxConnectionsPerHost = v;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? v) => _inner.userAgent = v;
  @override
  set authenticate(Future<bool> Function(Uri url, String scheme, String? realm)? f) => _inner.authenticate = f;
  @override
  set authenticateProxy(Future<bool> Function(String host, int port, String scheme, String? realm)? f) => _inner.authenticateProxy = f;
  @override
  set badCertificateCallback(bool Function(X509Certificate cert, String host, int port)? callback) =>
      _inner.badCertificateCallback = callback;
  @override
  set connectionFactory(Future<ConnectionTask<Socket>> Function(Uri url, String? proxyHost, int? proxyPort)? f) =>
      _inner.connectionFactory = f;
  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;
  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;
  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) => _inner.addCredentials(url, realm, credentials);
  @override
  void addProxyCredentials(String host, int port, String realm, HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);
  @override
  void close({bool force = false}) => _inner.close(force: force);
}
