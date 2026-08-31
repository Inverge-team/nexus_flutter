import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'identity.dart';

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
  /// failure (logged when [NexusConfig.logging] is on).
  Future<Map<String, dynamic>?> post(String path, Map<String, Object?> body) async {
    final uri = Uri.parse('${_config.httpBase}$path');
    try {
      final res = await _client
          .post(uri, headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (res.body.isEmpty) return <String, dynamic>{};
        final decoded = jsonDecode(res.body);
        return decoded is Map<String, dynamic> ? decoded : {'data': decoded};
      }
      _log('POST $path -> ${res.statusCode} ${res.body}');
      return null;
    } catch (e) {
      _log('POST $path failed: $e');
      return null;
    }
  }

  void _log(String msg) {
    if (_config.logging) debugPrint('[Nexus] $msg');
  }

  void close() => _client.close();
}
