import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The app's self-declared identity, sent on every Nexus request so API keys
/// restricted to apps with **basic** verification (console → API keys →
/// Application restrictions) accept it:
///
///  - Android: `X-Android-Package` + `X-Android-Cert` (signing-certificate SHA-256)
///  - iOS: `X-Ios-Bundle-Identifier`
///
/// Browsers send `Origin` themselves. Free, and stops casual reuse of a copied
/// key; Shield-attested verification is what makes it unforgeable.
///
/// Persisted so isolates started while the app is killed (incoming call, silent
/// push) send it too.
class NexusAppIdentity {
  NexusAppIdentity._();

  static const _pref = 'nexus_app_identity_v1';
  static Map<String, String>? _headers;

  /// Headers for this app (empty when unknown, e.g. web).
  static Map<String, String> get headers => _headers ?? const {};

  /// Build from the native device info (main isolate, at Nexus.init).
  static Future<void> init(Map<String, Object?> deviceContext) async {
    final os = deviceContext['osType'];
    final appId = deviceContext['appId'];
    final certs = (deviceContext['signingCerts'] as List?)?.whereType<String>().toList() ?? const <String>[];
    final h = <String, String>{};
    if (appId is String && appId.isNotEmpty) {
      if (os == 'android') {
        h['X-Android-Package'] = appId;
        if (certs.isNotEmpty) h['X-Android-Cert'] = certs.join(',');
      } else if (os == 'ios') {
        h['X-Ios-Bundle-Identifier'] = appId;
      }
    }
    _headers = h;
    try {
      await (await SharedPreferences.getInstance()).setString(_pref, jsonEncode(h));
    } catch (_) {}
  }

  /// The headers, reading what the main isolate persisted when this isolate never ran Nexus.init.
  static Future<Map<String, String>> load() async {
    final cached = _headers;
    if (cached != null) return cached;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_pref);
      final j = raw == null ? null : jsonDecode(raw);
      return _headers = j is Map ? j.map((k, v) => MapEntry('$k', '$v')) : const {};
    } catch (_) {
      return const {};
    }
  }

  /// The same identity as Socket.IO handshake `auth` fields.
  static Map<String, String> socketAuth() {
    final h = headers;
    return {
      if (h['X-Android-Package'] != null) 'androidPackage': h['X-Android-Package']!,
      if (h['X-Android-Cert'] != null) 'androidCert': h['X-Android-Cert']!,
      if (h['X-Ios-Bundle-Identifier'] != null) 'iosBundleId': h['X-Ios-Bundle-Identifier']!,
    };
  }
}
