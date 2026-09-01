import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'identity.dart';
import 'logging.dart';

/// Thin JSON transport over the `/partner/*` data-plane endpoints. Attaches the
/// API key + client-OS headers; never throws into the caller's hot path.
class NexusHttp {
  NexusHttp(this._config, this._identity, {http.Client? client})
      : _client = client ?? http.Client();

  final NexusConfig _config;
  final NexusIdentity _identity;
  final http.Client _client;

  Map<String, String> get _headers {
    final os = _identity.deviceContext['osType'];
    final osVersion = _identity.deviceContext['osVersion'];
    return {
      'content-type': 'application/json',
      'x-api-key': _config.apiKey,
      if (os is String) 'x-client-os': os,
      if (osVersion is String) 'x-client-os-version': osVersion,
    };
  }

  /// POST JSON to a `/partner/...` path. Returns the decoded body, or null on
  /// failure. Every request is traced at debug level; non-2xx and errors are
  /// logged at warn/error so failures are never silent.
  Future<Map<String, dynamic>?> post(String path, Map<String, Object?> body) async {
    final uri = Uri.parse('${_config.httpBase}$path');
    final sw = Stopwatch()..start();
    NexusLog.debug('→ POST $path');
    try {
      final res = await _client
          .post(uri, headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      final ms = sw.elapsedMilliseconds;
      if (res.statusCode >= 200 && res.statusCode < 300) {
        NexusLog.debug('← ${res.statusCode} POST $path (${ms}ms)');
        if (res.body.isEmpty) return <String, dynamic>{};
        final decoded = jsonDecode(res.body);
        return decoded is Map<String, dynamic> ? decoded : {'data': decoded};
      }
      NexusLog.warn('← ${res.statusCode} POST $path (${ms}ms) — ${_summarize(res.body)}');
      return null;
    } catch (e, st) {
      NexusLog.error('POST $path failed after ${sw.elapsedMilliseconds}ms', e, st);
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
