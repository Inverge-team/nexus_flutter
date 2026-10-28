import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Returns the signed-in end user's token from your identity provider
/// (Firebase Auth, Auth0, Cognito, your server…), or null when signed out.
/// [forceRefresh] is true after the server rejected the previous one.
typedef DocStoreTokenProvider = FutureOr<String?> Function({required bool forceRefresh});

/// Every DocStore failure. Unlike the telemetry services, a database call must
/// tell you WHY it failed.
class DocStoreException implements Exception {
  DocStoreException(this.message, this.code, this.status, [this.details]);

  final String message;

  /// `permission_denied`, `not_found`, `conflict`, `validation_failed`,
  /// `unauthorized`, `billing_suspended`, … or `network` / `service_disabled`.
  final String code;
  final int status;
  final Object? details;

  /// A version precondition failed — someone else wrote first.
  bool get isPreconditionFailed => code == 'conflict' && details is Map && (details as Map)['reason'] == 'precondition_failed';

  @override
  String toString() => 'DocStoreException($code, $status): $message';
}

class DocStoreOptions {
  const DocStoreOptions({
    required this.apiKey,
    this.baseUrl = 'https://services.inverge.net',
    this.realtimeUrl,
    this.getToken,
    this.serviceKey,
    this.timeout = const Duration(seconds: 30),
  });

  final String apiKey;
  final String baseUrl;

  /// Socket.IO origin for live queries; defaults to [baseUrl].
  final String? realtimeUrl;
  final DocStoreTokenProvider? getToken;

  /// SERVER-SIDE ONLY (Dart backends): bypasses security rules. Never ship in an app.
  final String? serviceKey;
  final Duration timeout;
}

/// HTTP transport for `/partner/docstore/*`. Throws [DocStoreException].
class DocStoreHttp {
  DocStoreHttp(this.options, {http.Client? client, bool Function()? enabled})
      : _client = client ?? http.Client(),
        _enabled = enabled ?? (() => true),
        base = '${options.baseUrl.replaceAll(RegExp(r'/+$'), '')}/partner/docstore';

  final DocStoreOptions options;
  final http.Client _client;
  final bool Function() _enabled;
  final String base;

  Future<String?> token({bool forceRefresh = false}) async => options.getToken == null ? null : await options.getToken!(forceRefresh: forceRefresh);

  Future<Object?> request(String method, String path, {Object? body, Map<String, String?>? query}) async {
    if (!_enabled()) throw DocStoreException('DocStore is switched off (NexusConfig.docStoreEnabled)', 'service_disabled', 0);
    final q = {for (final e in (query ?? const <String, String?>{}).entries) if (e.value != null) e.key: e.value!};
    final uri = Uri.parse('$base$path').replace(queryParameters: q.isEmpty ? null : q);
    Future<http.Response> send(bool force) async {
      final headers = <String, String>{'content-type': 'application/json', 'x-api-key': options.apiKey};
      if (options.serviceKey != null) {
        headers['x-nexus-service-key'] = options.serviceKey!;
      } else {
        final t = await token(forceRefresh: force);
        if (t != null) headers['authorization'] = 'Bearer $t';
      }
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) req.body = jsonEncode(body);
      return http.Response.fromStream(await _client.send(req).timeout(options.timeout));
    }

    http.Response res;
    try {
      res = await send(false);
      // The token can expire between getToken() and the request.
      if (res.statusCode == 401 && options.getToken != null && options.serviceKey == null) res = await send(true);
    } catch (e) {
      throw DocStoreException('DocStore request failed: $e', 'network', 0);
    }
    Object? decoded;
    try {
      decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {}
    if (res.statusCode >= 400) {
      final err = decoded is Map ? decoded['error'] : null;
      throw DocStoreException(
        err is Map ? '${err['message']}' : 'DocStore $method $path → ${res.statusCode}',
        err is Map ? '${err['code']}' : 'http_${res.statusCode}',
        res.statusCode,
        err is Map ? err['details'] : null,
      );
    }
    return decoded;
  }

  void close() => _client.close();
}
