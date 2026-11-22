import 'dart:convert';

import 'package:http/http.dart' as http;

import 'billing_suspension.dart';
import 'app_identity.dart';
import 'config.dart';
import 'identity.dart';
import 'logging.dart';
import 'shield/shield_signing.dart';

/// Thin JSON transport over the `/partner/*` data-plane endpoints. Attaches the
/// API key + client-OS headers; never throws into the caller's hot path.
///
/// Every call passes the billing-suspension breaker ([NexusBillingSuspension]):
/// after a 402 `billing_suspended` nothing is sent until the pause ends —
/// calls return null, the same "no answer" every caller already handles.
class NexusHttp {
  NexusHttp(this._config, this._identity, {http.Client? client})
    : _client = client ?? http.Client(),
      suspensionKey = NexusBillingSuspension.keyFor(_config.httpBase, _config.apiKey);

  /// This client's key in [NexusBillingSuspension].
  final String suspensionKey;

  /// Whether calls are currently paused by a billing suspension.
  bool get suspended => NexusBillingSuspension.instance.remaining(suspensionKey) > Duration.zero;

  bool _admit(String path) {
    if (NexusBillingSuspension.instance.begin(suspensionKey, path)) return true;
    NexusLog.debug('skipped POST $path — billing suspended');
    return false;
  }

  void _observe(String path, int status, Object? decoded) {
    final error = decoded is Map ? decoded['error'] : null;
    final seconds = NexusBillingSuspension.instance.record(
      suspensionKey,
      path,
      status,
      code: error is Map ? error['code'] : null,
      details: error is Map ? error['details'] : null,
    );
    if (seconds != null) {
      NexusLog.warn('API access is suspended for an overdue invoice — pausing every Nexus call for ${seconds}s');
    }
  }

  final NexusConfig _config;
  final NexusIdentity _identity;
  final http.Client _client;

  /// Called on `403 api_key_restricted` (the key only accepts attested apps)
  /// with the reason; resolves true when the request should be retried — Shield
  /// signing is then on ([NexusShieldSigning.active]). Set by Nexus.
  Future<bool> Function(String reason)? onRestricted;

  /// Shield headers on Nexus's own requests while signing is active (opted in
  /// via [NexusConfig.shieldProtectNexus], or the key turned out restricted).
  /// Never applied to `/partner/shield/*` — that is where tokens come from.
  Future<Map<String, String>> _sign(Uri uri, String path, List<int> body, {bool forceRefresh = false}) async {
    if (path.startsWith('/partner/shield') || !NexusShieldSigning.active) return const {};
    return NexusShieldSigning.headers('POST', uri, body: body, forceRefresh: forceRefresh);
  }

  /// One retry after a restriction refusal, signed (with a fresh token when the old one was refused).
  Future<bool> _retryRestricted(String path, http.Response res) async {
    final hook = onRestricted;
    if (hook == null || path.startsWith('/partner/shield')) return false;
    final reason = NexusShieldSigning.restrictionReason(res.statusCode, _decode(res.body));
    if (reason == null) return false;
    return hook(reason);
  }

  /// Like [post] but returns the status and decoded body for ANY response, so
  /// callers that need the server's error code can read it. Null only when the
  /// request itself failed (network, timeout).
  Future<({int status, Map<String, dynamic>? body})?> postRaw(
    String path,
    Map<String, Object?> body, {
    Map<String, String>? extraHeaders,
  }) async {
    if (!_admit(path)) {
      return (status: 402, body: <String, dynamic>{'error': {'code': 'billing_suspended', 'message': 'API access is suspended for an overdue invoice'}});
    }
    final uri = Uri.parse('${_config.httpBase}$path');
    NexusLog.debug('→ POST $path');
    try {
      final res = await _client
          .post(uri, headers: {..._headers, ...?extraHeaders}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));
      NexusLog.debug('← ${res.statusCode} POST $path');
      Map<String, dynamic>? decoded;
      try {
        final d = res.body.isEmpty ? null : jsonDecode(res.body);
        decoded = d is Map<String, dynamic> ? d : null;
      } catch (_) {}
      _observe(path, res.statusCode, decoded);
      if (res.statusCode >= 400) NexusLog.warn('← ${res.statusCode} POST $path — ${_summarize(res.body)}');
      return (status: res.statusCode, body: decoded);
    } catch (e, st) {
      NexusLog.error('POST $path failed', e, st);
      return null;
    }
  }

  Map<String, String> get _headers {
    final os = _identity.deviceContext['osType'];
    final osVersion = _identity.deviceContext['osVersion'];
    return {
      'content-type': 'application/json',
      'x-api-key': _config.apiKey,
      ...NexusAppIdentity.headers,
      if (os is String) 'x-client-os': os,
      if (osVersion is String) 'x-client-os-version': osVersion,
    };
  }

  /// POST JSON to a `/partner/...` path. Returns the decoded body, or null on
  /// failure. Every request is traced at debug level; non-2xx and errors are
  /// logged at warn/error so failures are never silent. [extraHeaders] are
  /// merged over the defaults (e.g. `If-None-Match` for conditional fetches).
  Future<Map<String, dynamic>?> post(
    String path,
    Map<String, Object?> body, {
    Map<String, String>? extraHeaders,
  }) async {
    if (!_admit(path)) return null;
    final uri = Uri.parse('${_config.httpBase}$path');
    final sw = Stopwatch()..start();
    NexusLog.debug('→ POST $path');
    try {
      final encoded = utf8.encode(jsonEncode(body));
      Future<http.Response> send({bool forceRefresh = false}) async => _client
          .post(
            uri,
            headers: {..._headers, ...await _sign(uri, path, encoded, forceRefresh: forceRefresh), ...?extraHeaders},
            body: encoded,
          )
          .timeout(const Duration(seconds: 20));
      var res = await send();
      if (res.statusCode == 403 && await _retryRestricted(path, res)) {
        res = await send(forceRefresh: NexusShieldSigning.restrictionReason(res.statusCode, _decode(res.body)) == 'shield_token_invalid');
      }
      final ms = sw.elapsedMilliseconds;
      _observe(path, res.statusCode, res.statusCode == 402 ? _decode(res.body) : null);
      if (res.statusCode == 402) return null; // logged once by _observe
      if (res.statusCode >= 200 && res.statusCode < 300) {
        NexusLog.debug('← ${res.statusCode} POST $path (${ms}ms)');
        if (res.body.isEmpty) return <String, dynamic>{};
        final decoded = jsonDecode(res.body);
        return decoded is Map<String, dynamic> ? decoded : {'data': decoded};
      }
      NexusLog.warn(
        '← ${res.statusCode} POST $path (${ms}ms) — ${_summarize(res.body)}',
      );
      return null;
    } catch (e, st) {
      NexusLog.error(
        'POST $path failed after ${sw.elapsedMilliseconds}ms',
        e,
        st,
      );
      return null;
    }
  }

  static Object? _decode(String body) {
    try {
      return body.isEmpty ? null : jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// Compact an error body for a single log line (full body would be noisy).
  static String _summarize(String body) {
    final trimmed = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return trimmed.length > 300 ? '${trimmed.substring(0, 300)}…' : trimmed;
  }

  void close() => _client.close();
}
