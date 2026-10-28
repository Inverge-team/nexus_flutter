import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../nexus_platform_interface.dart';
import '../config.dart';
import '../http_client.dart';
import '../logging.dart';
import 'jose.dart';

/// A device-bound Shield token. Useless on its own: every request must also
/// carry a fresh DPoP proof from this device's hardware key — use
/// [NexusShield.headers] (or [NexusShieldClient]) rather than sending
/// [value] by hand.
class NexusShieldToken {
  NexusShieldToken._(this.value, this.expiresAt, this.refreshAt, this.score, this.level, this.deviceId);

  final String value;
  final DateTime expiresAt;
  final DateTime refreshAt;

  /// Risk score 0–100 the backend assigned at issue time.
  final int score;

  /// `strong` · `device` · `basic` · `weak` · `debug`.
  final String level;
  final String deviceId;

  bool get isExpired => DateTime.now().isAfter(expiresAt.subtract(const Duration(seconds: 30)));
}

/// Nexus Shield — proves to your backend (and to Nexus) that a request comes
/// from your genuine app on a genuine device.
///
/// ```dart
/// await Nexus.init(const NexusConfig(apiKey: 'nxs_…', shieldEnabled: true));
///
/// // Any request to YOUR backend:
/// final headers = await Nexus.instance.shield.headers(method: 'POST', url: uri);
/// await http.post(uri, headers: {...headers, 'content-type': 'application/json'}, body: body);
///
/// // …or wrap a client once and forget about it:
/// final client = NexusShieldClient(http.Client());
/// ```
///
/// On Android the device key is generated in StrongBox/TEE and certified by
/// Google's hardware attestation; Play Integrity is added when the app is
/// configured for it in the console. On iOS the key lives in the Secure
/// Enclave and App Attest vouches for it. Tokens refresh automatically before
/// they expire. Failures never throw into your code: [headers] returns `{}`
/// and your backend's policy decides (monitor vs enforce).
class NexusShield {
  NexusShield(this._http, this._config);

  final NexusHttp _http;
  final NexusConfig _config;

  static const _alias = 'nexus_shield_device_key_v1';
  static const _prefToken = 'nexus_shield_token_v1';

  NexusShieldToken? _token;
  Completer<NexusShieldToken?>? _inflight;
  Timer? _refreshTimer;
  _DeviceKey? _key;
  DateTime? _backoffUntil;
  int _failures = 0;

  /// The current token (null until the first successful exchange).
  NexusShieldToken? get current => _token;

  /// Called whenever a new token is issued (score/level changes are visible here).
  void Function(NexusShieldToken token)? onToken;

  /// Called when an exchange is refused, with the backend's failure code.
  void Function(String failure)? onRefused;

  /// Warm up: restore a cached token and obtain one if needed (non-blocking).
  Future<void> start() async {
    if (!_supported) {
      NexusLog.info('shield: not supported on this platform — tokens disabled');
      return;
    }
    await _restore();
    unawaited(token());
  }

  bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// A valid token, exchanging (or refreshing) one if needed. Concurrent callers
  /// share one exchange. Null when one can't be obtained right now.
  Future<NexusShieldToken?> token({bool forceRefresh = false}) async {
    if (!_supported) return null;
    final t = _token;
    if (!forceRefresh && t != null && !t.isExpired) return t;
    if (_backoffUntil != null && DateTime.now().isBefore(_backoffUntil!) && !forceRefresh) return t;
    if (_inflight != null) return _inflight!.future;
    final c = _inflight = Completer<NexusShieldToken?>();
    try {
      final fresh = await _exchange(retryOnStaleKey: true);
      c.complete(fresh ?? t);
    } catch (e, st) {
      NexusLog.error('shield: exchange failed', e, st);
      c.complete(t);
    } finally {
      _inflight = null;
    }
    return c.future;
  }

  /// Headers proving THIS request comes from this device: `X-Nexus-Shield`
  /// (the token) and `DPoP` (a single-use proof for exactly [method] + [url]).
  /// Pass [body] to also bind the proof to the payload. Returns `{}` when no
  /// token can be had — never throws.
  Future<Map<String, String>> headers({required String method, required Uri url, List<int>? body}) async {
    try {
      final t = await token();
      final key = _key;
      if (t == null || key == null) return const {};
      final proof = await _proof(key, method: method, url: url, accessToken: t.value, body: body);
      if (proof == null) return const {};
      return {'X-Nexus-Shield': t.value, 'DPoP': proof};
    } catch (e, st) {
      NexusLog.error('shield: could not sign request', e, st);
      return const {};
    }
  }

  /// Forget the device key and token (e.g. on sign-out of a shared device). The
  /// next call creates and attests a brand-new key.
  Future<void> reset() async {
    _refreshTimer?.cancel();
    _token = null;
    _key = null;
    await NexusPlatform.instance.shieldDeleteKey(_alias);
    await NexusPlatform.instance.shieldAppAttestReset();
    final p = await SharedPreferences.getInstance();
    await p.remove(_prefToken);
  }

  void dispose() => _refreshTimer?.cancel();

  // ---------------------------------------------------------------------------

  Future<NexusShieldToken?> _exchange({required bool retryOnStaleKey}) async {
    final ch = await _http.post('/partner/shield/challenge', {'app': _appRef});
    final challenge = ch?['challenge'] as String?;
    if (challenge == null) return _fail('challenge_unavailable');
    final app = (ch?['app'] as Map?)?.cast<String, Object?>();
    final providers = ((app?['providers'] as List?) ?? const []).cast<String>();
    if (app == null) NexusLog.warn('shield: app "$_appRef" is not registered in the console (Shield → Apps)');

    // 1. Device key (created + hardware-attested on first use).
    final info = await NexusPlatform.instance.shieldEnsureKey(
      _alias,
      attestationChallenge: Platform.isAndroid ? keyAttestationChallenge(challenge) : null,
    );
    if (info == null) return _fail('key_unavailable');
    final key = _key = _DeviceKey(info['x'] as String, info['y'] as String, ((info['chain'] as List?) ?? const []).cast<String>());
    final binding = bindingHash(challenge, key.jkt);

    // 2. Evidence.
    final evidence = <String, Object?>{};
    final debugToken = _config.shieldDebugToken;
    if (debugToken != null && debugToken.isNotEmpty) {
      evidence['debug'] = {'token': debugToken};
    } else if (Platform.isAndroid) {
      if (providers.isEmpty || providers.contains('key_attestation')) {
        if (key.chain.isNotEmpty) evidence['keyAttestation'] = {'chain': key.chain};
      }
      final project = app?['playCloudProjectNumber'] as String?;
      if (providers.contains('play_integrity') && project != null) {
        try {
          final t = await NexusPlatform.instance.shieldPlayIntegrity(project, b64url(binding));
          if (t != null) evidence['playIntegrity'] = {'token': t};
        } catch (e) {
          NexusLog.warn('shield: Play Integrity unavailable ($e) — continuing with key attestation');
        }
      }
    } else if (Platform.isIOS && (providers.isEmpty || providers.contains('app_attest'))) {
      if (await NexusPlatform.instance.shieldAppAttestSupported()) {
        try {
          final r = await NexusPlatform.instance.shieldAppAttest(binding);
          if (r != null) {
            evidence['appAttest'] = {
              'keyId': r['keyId'],
              if (r['attestation'] != null) 'attestation': r['attestation'],
              if (r['assertion'] != null) 'assertion': r['assertion'],
            };
          }
        } catch (e) {
          NexusLog.warn('shield: App Attest failed ($e)');
        }
      }
    }
    if (evidence.isEmpty && providers.contains('pow')) {
      final difficulty = (app?['powDifficulty'] as num?)?.toInt() ?? 20;
      evidence['pow'] = {'nonce': await compute(solvePow, {'binding': binding, 'difficulty': difficulty})};
    }
    if (evidence.isEmpty) return _fail('no_evidence');

    // 3. Exchange, proving possession of the key over this very request.
    final url = Uri.parse('${_config.httpBase}/partner/shield/exchange');
    final proof = await _proof(key, method: 'POST', url: url, nonce: challenge);
    if (proof == null) return _fail('sign_failed');
    final res = await _http.postRaw('/partner/shield/exchange', {
      'app': _appRef,
      'challenge': challenge,
      'jwk': key.jwk,
      'evidence': evidence,
    }, extraHeaders: {'DPoP': proof});

    if (res == null) return _fail('network');
    if (res.status != 200) {
      final failure = ((res.body?['error'] as Map?)?['details'] as Map?)?['failure'] as String? ?? 'http_${res.status}';
      // A key certified for a challenge that never completed an exchange (app
      // killed mid-exchange) can never be pinned — start over with a new key.
      if (retryOnStaleKey && failure == 'challenge_mismatch' && Platform.isAndroid) {
        await NexusPlatform.instance.shieldDeleteKey(_alias);
        return _exchange(retryOnStaleKey: false);
      }
      if (retryOnStaleKey && (failure == 'key_not_attested' || failure == 'key_already_attested') && Platform.isIOS) {
        await NexusPlatform.instance.shieldAppAttestReset();
        return _exchange(retryOnStaleKey: false);
      }
      onRefused?.call(failure);
      return _fail(failure);
    }

    final d = res.body ?? const {};
    final now = DateTime.now();
    final token = NexusShieldToken._(
      d['token'] as String,
      DateTime.parse(d['expiresAt'] as String).toLocal(),
      now.add(Duration(seconds: (d['refreshIn'] as num?)?.toInt() ?? 2700)),
      (d['score'] as num?)?.toInt() ?? 0,
      d['level'] as String? ?? 'weak',
      d['deviceId'] as String? ?? '',
    );
    _token = token;
    _failures = 0;
    _backoffUntil = null;
    _schedule(token);
    unawaited(_persist(token));
    NexusLog.info('shield: token issued (score ${token.score}, ${token.level})');
    onToken?.call(token);
    return token;
  }

  NexusShieldToken? _fail(String reason) {
    _failures++;
    final wait = Duration(seconds: (15 * (1 << (_failures.clamp(1, 6) - 1))).clamp(15, 600));
    _backoffUntil = DateTime.now().add(wait);
    NexusLog.warn('shield: no token ($reason) — retrying in ${wait.inSeconds}s');
    return null;
  }

  void _schedule(NexusShieldToken t) {
    _refreshTimer?.cancel();
    final delay = t.refreshAt.difference(DateTime.now());
    _refreshTimer = Timer(delay.isNegative ? Duration.zero : delay, () => unawaited(token(forceRefresh: true)));
  }

  Future<String?> _proof(
    _DeviceKey key, {
    required String method,
    required Uri url,
    String? accessToken,
    String? nonce,
    List<int>? body,
  }) async {
    // RFC 9449: htu is the URL without query and fragment.
    final htu = '${url.scheme}://${url.authority}${url.path.isEmpty ? '/' : url.path}';
    final header = b64urlJson({'typ': 'dpop+jwt', 'alg': 'ES256', 'jwk': key.jwk});
    final payload = b64urlJson({
      'jti': randomId(),
      'htm': method.toUpperCase(),
      'htu': htu,
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      if (accessToken != null) 'ath': b64url(sha256Of(accessToken)),
      'nonce': ?nonce,
      if (body != null) 'bh': b64url(sha256Bytes(body)),
    });
    final input = '$header.$payload';
    final der = await NexusPlatform.instance.shieldSign(_alias, Uint8List.fromList(utf8.encode(input)));
    if (der == null) return null;
    return '$input.${b64url(derToJose(der))}';
  }

  /// `platform:appId` unless the app overrides it ([NexusConfig.shieldApp]).
  String get _appRef => _config.shieldApp ?? '${Platform.isIOS ? 'ios' : 'android'}:${appId ?? ''}';

  /// The package / bundle id, from native device info (set by Nexus at init).
  String? appId;

  Future<void> _persist(NexusShieldToken t) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _prefToken,
      jsonEncode({'v': t.value, 'e': t.expiresAt.toIso8601String(), 'r': t.refreshAt.toIso8601String(), 's': t.score, 'l': t.level, 'd': t.deviceId}),
    );
  }

  Future<void> _restore() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_prefToken);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final t = NexusShieldToken._(j['v'] as String, DateTime.parse(j['e'] as String), DateTime.parse(j['r'] as String),
          (j['s'] as num).toInt(), j['l'] as String, j['d'] as String);
      if (t.isExpired) return;
      // The token is only usable with the key that it is bound to.
      final info = await NexusPlatform.instance.shieldEnsureKey(_alias);
      if (info == null) return;
      _key = _DeviceKey(info['x'] as String, info['y'] as String, ((info['chain'] as List?) ?? const []).cast<String>());
      _token = t;
      _schedule(t);
    } catch (_) {
      // A corrupt cache just means one extra exchange.
    }
  }
}

class _DeviceKey {
  _DeviceKey(this.x, this.y, this.chain) : jkt = jwkThumbprint(x, y);
  final String x;
  final String y;
  final List<String> chain;
  final String jkt;
  Map<String, String> get jwk => {'kty': 'EC', 'crv': 'P-256', 'x': x, 'y': y};
}

/// A `package:http` client that signs every request with Shield headers.
///
/// ```dart
/// final api = NexusShieldClient(http.Client());
/// await api.post(Uri.parse('https://api.example.com/checkout'), body: jsonBody);
/// ```
class NexusShieldClient extends http.BaseClient {
  // ignore: prefer_initializing_formals — a named parameter can't be private.
  NexusShieldClient(this._inner, {NexusShield? shield, this.bindBody = true}) : _shield = shield;

  final http.Client _inner;
  final NexusShield? _shield;

  /// Also bind the proof to the request body (`bh`) when it is buffered.
  final bool bindBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final shield = _shield ?? _globalShield?.call();
    if (shield != null) {
      final body = bindBody && request is http.Request ? request.bodyBytes : null;
      request.headers.addAll(await shield.headers(method: request.method, url: request.url, body: body));
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// Set by Nexus at init so [NexusShieldClient] works without an explicit instance.
NexusShield? Function()? _globalShield;
void registerGlobalShield(NexusShield? Function() f) => _globalShield = f;
