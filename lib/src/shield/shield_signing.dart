import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';
import 'shield_service.dart';

/// The ONE place every path that talks to Nexus asks "does this request need a
/// Shield token, and what are its headers?" — NexusHttp, realtime and DocStore
/// sockets, DocStore HTTP, Push Authentication, the headless voice isolate.
///
/// Signing is **active** when the app opted in ([NexusConfig.shieldProtectNexus])
/// or when Nexus answered `403 api_key_restricted` (the console restricted the
/// key to attested apps) — then it stays on, and is remembered so the next
/// launch, and isolates started while the app is killed (an incoming call, a
/// silent push), sign from their very first request.
///
/// In an isolate where [Nexus.init] never ran, a small [NexusShield] is rebuilt
/// from what the main isolate persisted (API key, base URL, Shield app, debug
/// token): it restores the cached token and the hardware key, and exchanges a
/// new token itself if the cached one expired.
class NexusShieldSigning {
  NexusShieldSigning._();

  static const _prefState = 'nexus_shield_signing_v1';

  static NexusShield? Function()? _live;
  static NexusConfig? _config;
  static String? _appId;
  static bool _active = false;
  static NexusShield? _background;
  static Future<NexusShield?>? _backgroundInit;

  /// Whether Nexus requests are being signed in this isolate. In a background
  /// isolate this only turns true once [headers] loaded the persisted state —
  /// so code that may run there calls [headers] unconditionally (it returns
  /// `{}` when signing is off).
  static bool get active => _active;

  /// Called by Nexus.init (main isolate).
  static Future<void> attach(NexusConfig config, NexusShield Function() live, {String? appId}) async {
    _live = live;
    _config = config;
    _appId = appId;
    final saved = await _read();
    _active = config.shieldProtectNexus || (saved?['active'] == true && saved?['apiKey'] == config.apiKey);
    await _write(config, appId: appId, active: _active);
  }

  /// Turn signing on after Nexus said the key is restricted to apps. False
  /// when Shield isn't enabled in this app (nothing could sign).
  static Future<bool> activate() async {
    final config = _config;
    if (_live == null || config == null) return _background != null;
    if (!_active) NexusLog.info('shield: this API key is restricted to attested apps — signing every Nexus request');
    _active = true;
    await _write(config, appId: _appId, active: true);
    return true;
  }

  /// Headers for a Nexus request (`{}` when signing is off or no token can be
  /// had). [separateProof] puts the proof in `X-Nexus-Shield-Proof` instead of
  /// `DPoP`, for requests that already carry their own DPoP (Push Auth).
  static Future<Map<String, String>> headers(
    String method,
    Uri url, {
    List<int>? body,
    bool separateProof = false,
    bool forceRefresh = false,
  }) async {
    try {
      final shield = await _shield();
      if (shield == null) return const {};
      if (forceRefresh) await shield.token(forceRefresh: true);
      final h = await shield.headers(method: method, url: url, body: body);
      if (!separateProof || !h.containsKey('DPoP')) return h;
      return {'X-Nexus-Shield': h['X-Nexus-Shield']!, 'X-Nexus-Shield-Proof': h['DPoP']!};
    } catch (e, st) {
      NexusLog.error('shield: could not sign Nexus request', e, st);
      return const {};
    }
  }

  /// Socket.IO handshake fields (`auth.shield` / `auth.dpop`) — a fresh,
  /// single-use proof for every (re)connect.
  static Future<Map<String, String>> socketAuth(String socketBase, {bool forceRefresh = false}) async {
    final h = await headers('GET', Uri.parse('$socketBase/socket.io/'), forceRefresh: forceRefresh);
    return {
      if (h['X-Nexus-Shield'] != null) 'shield': h['X-Nexus-Shield']!,
      if (h['DPoP'] != null) 'dpop': h['DPoP']!,
    };
  }

  /// Is this a "your key needs a (fresh) Shield token" refusal? Returns the reason.
  static String? restrictionReason(int status, Object? decodedBody) {
    if (status != 403 || decodedBody is! Map) return null;
    final err = decodedBody['error'];
    if (err is! Map || err['code'] != 'api_key_restricted') return null;
    final reason = (err['details'] as Map?)?['reason'];
    return reason is String ? reason : 'app_not_allowed';
  }

  static Future<NexusShield?> _shield() async {
    final live = _live;
    if (live != null) return _active ? live() : null;
    return _background ?? await (_backgroundInit ??= _loadBackground());
  }

  static Future<NexusShield?> _loadBackground() async {
    final s = await _read();
    if (s == null || s['active'] != true) return null;
    final config = NexusConfig(
      apiKey: s['apiKey'] as String,
      baseUrl: s['baseUrl'] as String,
      shieldEnabled: true,
      shieldApp: s['shieldApp'] as String?,
      shieldDebugToken: s['debugToken'] as String?,
    );
    final shield = NexusShield(NexusHttp(config, NexusIdentity()), config)..appId = s['appId'] as String?;
    await shield.start();
    _active = true;
    return _background = shield;
  }

  static Future<Map<String, Object?>?> _read() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_prefState);
      if (raw == null) return null;
      final j = jsonDecode(raw);
      return j is Map ? j.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _write(NexusConfig c, {String? appId, required bool active}) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        _prefState,
        jsonEncode({
          'active': active,
          'apiKey': c.apiKey,
          'baseUrl': c.httpBase,
          'shieldApp': c.shieldApp,
          // A debug token only ever exists in debug builds (dart-define).
          'debugToken': c.shieldDebugToken,
          'appId': appId,
        }),
      );
    } catch (_) {}
  }
}
