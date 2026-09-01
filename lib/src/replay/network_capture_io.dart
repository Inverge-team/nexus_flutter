import 'dart:convert';
import 'dart:io';

/// Reports one observed request. `size` is null when the length is unknown.
typedef NetworkRecord = void Function({
  required String url,
  required String method,
  required int status,
  required int durationMs,
  int? size,
});

/// Automatic network capture via `HttpOverrides` — observes every `dart:io`
/// HTTP request in the app, so it covers **both Dio and `package:http`** (and any
/// dart:io client) without the app wiring anything. Requests to the Nexus API
/// itself are ignored so telemetry isn't recorded (and can't feed back).
class NexusNetworkCapture {
  static bool _active = false;
  static HttpOverrides? _previous;

  /// Whether automatic capture is currently installed (so a manual interceptor
  /// can avoid double-recording).
  static bool get isActive => _active;

  static void install({
    required bool Function() isRecording,
    required bool Function(Uri url) ignore,
    required NetworkRecord record,
  }) {
    if (_active) return;
    _previous = HttpOverrides.current;
    HttpOverrides.global = _NexusHttpOverrides(_previous, isRecording, ignore, record);
    _active = true;
  }

  static void uninstall() {
    if (!_active) return;
    HttpOverrides.global = _previous;
    _previous = null;
    _active = false;
  }
}

class _NexusHttpOverrides extends HttpOverrides {
  _NexusHttpOverrides(this._previous, this._isRecording, this._ignore, this._record);

  final HttpOverrides? _previous;
  final bool Function() _isRecording;
  final bool Function(Uri) _ignore;
  final NetworkRecord _record;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = _previous?.createHttpClient(context) ?? super.createHttpClient(context);
    return _ObservingHttpClient(inner, _isRecording, _ignore, _record);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    return _previous?.findProxyFromEnvironment(url, environment) ??
        super.findProxyFromEnvironment(url, environment);
  }
}

/// Delegates everything to [_inner]; wraps request creation so `close()` can time
/// the round trip. All open/get/post/… paths funnel through [openUrl].
class _ObservingHttpClient implements HttpClient {
  _ObservingHttpClient(this._inner, this._isRecording, this._ignore, this._record);

  final HttpClient _inner;
  final bool Function() _isRecording;
  final bool Function(Uri) _ignore;
  final NetworkRecord _record;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = await _inner.openUrl(method, url);
    if (_ignore(url)) return request; // e.g. the Nexus API — never record
    return _ObservingHttpClientRequest(request, () {
      if (!_isRecording()) return null;
      return _RecordCtx(method, url, _record);
    });
  }

  @override
  Future<HttpClientRequest> open(String method, String host, int port, String path) =>
      openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) => open('GET', host, port, path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) => open('POST', host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) => open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) => open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) => open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) => open('HEAD', host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  // ---- pure delegation below ----

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;
  @override
  set authenticateProxy(
          Future<bool> Function(String host, int port, String scheme, String? realm)? f) =>
      _inner.authenticateProxy = f;
  @override
  set badCertificateCallback(bool Function(X509Certificate cert, String host, int port)? cb) =>
      _inner.badCertificateCallback = cb;
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(Uri url, String? proxyHost, int? proxyPort)? f) =>
      _inner.connectionFactory = f;
  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;
  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);
  @override
  void addProxyCredentials(String host, int port, String realm, HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// Carries what we need to record when the request completes.
class _RecordCtx {
  _RecordCtx(this.method, this.url, this.record);
  final String method;
  final Uri url;
  final NetworkRecord record;
  final int start = DateTime.now().millisecondsSinceEpoch;
}

/// Delegates to [_inner]; on `close()` records the round trip (if recording).
class _ObservingHttpClientRequest implements HttpClientRequest {
  _ObservingHttpClientRequest(this._inner, this._begin);

  final HttpClientRequest _inner;
  final _RecordCtx? Function() _begin;

  @override
  Future<HttpClientResponse> close() async {
    final ctx = _begin();
    if (ctx == null) return _inner.close();
    var status = 0;
    int? size;
    try {
      final response = await _inner.close();
      status = response.statusCode;
      size = response.contentLength >= 0 ? response.contentLength : null;
      return response;
    } finally {
      ctx.record(
        url: ctx.url.toString(),
        method: ctx.method,
        status: status,
        durationMs: DateTime.now().millisecondsSinceEpoch - ctx.start,
        size: size,
      );
    }
  }

  // ---- delegation ----

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;
  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;
  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;
  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  HttpHeaders get headers => _inner.headers;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  String get method => _inner.method;
  @override
  Uri get uri => _inner.uri;
  @override
  Future<HttpClientResponse> get done => _inner.done;

  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  Future<void> flush() => _inner.flush();
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) => _inner.abort(exception, stackTrace);
}
