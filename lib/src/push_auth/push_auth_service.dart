import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../nexus_platform_interface.dart';
import '../config.dart';
import '../logging.dart';
import '../services/realtime_service.dart';
import '../shield/jose.dart';
import 'api.dart';
import 'canonical.dart';
import 'methods.dart';

export 'api.dart' show NexusPushAuthException;

const _prefKey = 'nexus_push_auth_v1';
const _keyPrefix = 'nexus_push_auth';
const _realtimeEvent = 'nexus:push_auth';

/// The enrolled device, as Nexus knows it.
class NexusPushAuthFactor {
  NexusPushAuthFactor._(this.id, this.identity, this.friendlyName, this.keyStrength, this.attested);

  final String id;

  /// Your user id this phone approves for.
  final String identity;
  final String friendlyName;

  /// `strongbox` · `tee` · `secure_enclave` · `software` · `unknown`.
  final String keyStrength;

  /// The keys were proven by hardware attestation at enrollment.
  final bool attested;

  static NexusPushAuthFactor _from(Map<String, dynamic> j) => NexusPushAuthFactor._(
        j['id'] as String,
        j['identity'] as String,
        (j['friendlyName'] as String?) ?? '',
        (j['keyStrength'] as String?) ?? 'unknown',
        (j['attested'] as bool?) ?? false,
      );
}

/// One labelled line of a request ("Amount · 25,000 IQD").
class NexusPushAuthField {
  const NexusPushAuthField(this.label, this.value);
  final String label;
  final String value;
}

/// The outcome of [NexusPushAuthRequest.approve] / [NexusPushAuthRequest.deny].
class NexusPushAuthResult {
  NexusPushAuthResult._(this.status, this.reason, this.code);

  /// `approved` · `denied` · `pending` (e.g. code display awaiting the code).
  final String status;
  final String? reason;

  /// `code_display`: the code to show the user, who types it on the sign-in screen.
  final String? code;

  bool get approved => status == 'approved';
}

/// An approval request on this device — render it, then [approve] or [deny].
class NexusPushAuthRequest {
  NexusPushAuthRequest._(this._svc, Map<String, dynamic> j)
      : id = j['id'] as String,
        factorId = j['factorId'] as String,
        status = j['status'] as String,
        stage = j['stage'] as String?,
        method = j['method'] as String,
        version = (j['v'] as num?)?.toInt() ?? 1,
        rev = (j['rev'] as num?)?.toInt() ?? 1,
        interactive = (j['interactive'] as bool?) ?? true,
        requiresUserPresence = (j['requiresUserPresence'] as bool?) ?? true,
        message = ((j['details'] as Map?)?['message'] as String?) ?? '',
        fields = [
          for (final f in ((j['details'] as Map?)?['fields'] as List?) ?? const [])
            NexusPushAuthField((f as Map)['label'] as String, f['value'] as String),
        ],
        context = (((j['details'] as Map?)?['context'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), v.toString())),
        view = ((j['view'] as Map?) ?? const {}).cast<String, Object?>(),
        expiresAt = DateTime.parse(j['expiresAt'] as String).toLocal(),
        createdAt = DateTime.parse(j['createdAt'] as String).toLocal();

  final NexusPushAuth? _svc;
  final String id;
  final String factorId;
  final String status;
  final String? stage;

  /// `tap` · `number_match` · `code_display` · `silent` (or a registered custom method).
  final String method;
  final int version;
  final int rev;
  final bool interactive;
  final bool requiresUserPresence;

  /// What is being approved. Shown to the user and signed over (see [canonicalJson]).
  final String message;
  final List<NexusPushAuthField> fields;

  /// Where the request came from: `device`, `location`, `ip`, `app` when your server sent them.
  final Map<String, String> context;

  /// Method-specific view — e.g. `{entry: 'choose', choices: ['37','82','15']}` for number matching.
  final Map<String, Object?> view;
  final DateTime expiresAt;
  final DateTime createdAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get isPending => status == 'pending' && !isExpired;

  /// This app can render the method (an unknown one is never approved).
  bool get isSupported => NexusPushAuthMethods.byId(method) != null;

  /// number_match: the numbers to offer (already shuffled for this device).
  List<String> get numberChoices => ((view['choices'] as List?) ?? const []).cast<String>();

  /// number_match: `choose` (tap one of [numberChoices]) or `type` (keypad).
  String get numberEntry => (view['entry'] as String?) ?? 'choose';

  int get numberDigits => (view['digits'] as num?)?.toInt() ?? 2;

  /// Approve. Interactive methods show the system biometric / device
  /// credential prompt first — the approval key can't sign without it.
  /// [number]: number_match's pick. [response]: a custom method's answer.
  Future<NexusPushAuthResult> approve({String? number, Map<String, Object?>? response, String? promptTitle}) =>
      _service._respond(this, 'approve', response: response ?? (number != null ? {'number': number} : null), promptTitle: promptTitle);

  /// Deny. [fraud] = "This wasn't me": your server is told and, by policy,
  /// the account's approvals are locked.
  Future<NexusPushAuthResult> deny({bool fraud = false}) => _service._respond(this, 'deny', reason: fraud ? 'fraud_reported' : 'user_denied');

  NexusPushAuth get _service => _svc ?? (throw NexusPushAuthException('not_enrolled', 'Push Authentication is not running'));

  Map<String, Object?> _detailsJson() => {
        'message': message,
        'fields': [for (final f in fields) {'label': f.label, 'value': f.value}],
        'context': context,
      };
}

/// Push Authentication — this phone as a hardware security key.
///
/// ```dart
/// await Nexus.init(const NexusConfig(apiKey: 'nxs_…', pushAuthEnabled: true));
///
/// // Enroll (token from YOUR server: POST /partner/push-auth/enrollments).
/// await Nexus.instance.pushAuth.enroll(token);
///
/// // Requests arrive by push, realtime and when the app opens:
/// Nexus.instance.pushAuth.requests.listen((r) => NexusPushAuthSheet.show(context, r));
/// ```
///
/// Two keys are created in secure hardware: an approval key that only unlocks
/// with Face ID / fingerprint / the device PIN (for every single approval), and
/// a silent key for silent approvals and for signing this device's requests.
/// Silent requests are answered in the background — even when the app is
/// killed — unless [NexusConfig.pushAuthSilentApproval] is off.
class NexusPushAuth {
  NexusPushAuth(this._config);

  final NexusConfig _config;
  PushAuthState? _state;
  PushAuthApi? _api;
  final _requests = StreamController<NexusPushAuthRequest>.broadcast();
  final _seen = <String, int>{};
  final _subs = <StreamSubscription<Object?>>[];
  NexusRealtime? _realtime;
  String? _identityAppId;

  /// Every request for this device, once, as soon as any path delivers it.
  /// Listen early (e.g. in your root widget) and show [NexusPushAuthSheet].
  Stream<NexusPushAuthRequest> get requests => _requests.stream;

  /// Requests the other devices answered (or that were cancelled) — dismiss any UI for them.
  final _closed = StreamController<String>.broadcast();
  Stream<String> get closed => _closed.stream;

  bool get isEnrolled => _state?.enrolled ?? false;
  String? get factorId => _state?.factorId;
  String? get identity => _state?.identity;

  bool get _platformOk => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Restore the enrollment and start listening (called by `Nexus.init`).
  Future<void> start({required NexusRealtime realtime, String? appId}) async {
    if (!_platformOk) return;
    _realtime = realtime;
    _identityAppId = appId;
    _state = await _load() ?? PushAuthState(apiKey: _config.apiKey, baseUrl: _config.httpBase, prefix: _keyPrefix);
    // The config may have changed since enrollment (key rotation, silent opt-out).
    _state = PushAuthState(
      apiKey: _config.apiKey,
      baseUrl: _config.httpBase,
      prefix: _state!.prefix,
      factorId: _state!.factorId,
      identity: _state!.identity,
      channel: _state!.channel,
      silentApproval: _config.pushAuthSilentApproval,
      presenceJkt: _state!.presenceJkt,
      silentJwk: _state!.silentJwk,
    );
    await _save();
    _api = PushAuthApi(_state!);
    _listenPush();
    if (!isEnrolled) return;
    _listenRealtime();
    unawaited(_syncFactor());
    unawaited(checkPending());
  }

  /// Is this device able to enroll? Null = yes, else `no_screen_lock`,
  /// `biometric_not_enrolled`, `android_version` or `unsupported`.
  Future<String?> unsupportedReason() async => _platformOk ? NexusPlatform.instance.pushAuthSupported() : 'unsupported';

  /// Enroll this phone for the identity your server minted [token] for. Shows
  /// the biometric / device-credential prompt once (to prove the approval key
  /// works). Replaces any earlier enrollment on this device.
  Future<NexusPushAuthFactor> enroll(String token, {String? friendlyName, String promptTitle = 'Use this phone to approve sign-ins'}) async {
    if (!_platformOk) throw NexusPushAuthException('unsupported', 'Push Authentication needs Android or iOS');
    final st = _state ??= PushAuthState(apiKey: _config.apiKey, baseUrl: _config.httpBase, prefix: _keyPrefix);
    final reason = await NexusPlatform.instance.pushAuthSupported();
    if (reason != null) throw NexusPushAuthException('unsupported', 'This device can’t enroll: $reason', reason: reason);
    if (st.enrolled) {
      try {
        await _api!.request('DELETE', '/device/factors/${st.factorId}');
      } catch (_) {
        // Best effort — the old factor is replaced either way.
      }
    }

    // 1. Two fresh hardware keys, certified for THIS enrollment.
    final keys = await NexusPlatform.instance.pushAuthCreateKeys(st.prefix, sha256Of('nexus-push-auth/v1/ka\n$token'));
    if (keys == null) throw NexusPushAuthException('unsupported', 'Keys could not be created');
    final p = (keys['presence'] as Map).cast<String, Object?>();
    final s = (keys['silent'] as Map).cast<String, Object?>();
    final presenceJwk = {'kty': 'EC', 'crv': 'P-256', 'x': p['x'] as String, 'y': p['y'] as String};
    final silentJwk = {'kty': 'EC', 'crv': 'P-256', 'x': s['x'] as String, 'y': s['y'] as String};
    final pjkt = jwkThumbprint(presenceJwk['x']!, presenceJwk['y']!);
    final sjkt = jwkThumbprint(silentJwk['x']!, silentJwk['y']!);

    // 2. Attestation evidence.
    final attestation = <String, Object?>{'claimedHardware': _weaker(p['hardware'] as String?, s['hardware'] as String?)};
    if (Platform.isAndroid) {
      attestation['android'] = {'presenceChain': p['chain'] ?? const [], 'silentChain': s['chain'] ?? const []};
    } else {
      final att = await NexusPlatform.instance.pushAuthAttest(sha256Of('nexus-push-auth/v1/enroll\n$token\n$pjkt\n$sjkt'));
      if (att != null) attestation['ios'] = {'keyId': att['keyId'], 'attestation': att['attestation']};
    }

    // 3. Prove the approval key works (this is the one prompt at enrollment).
    final api = PushAuthApi(st);
    final header = b64urlJson({'typ': 'nexus-push-auth-enroll+jwt', 'alg': 'ES256'});
    final payload = b64urlJson({'eth': b64url(sha256Of(token)), 'sjkt': sjkt, 'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000});
    final String presenceProof;
    try {
      presenceProof = await api.signJws('$header.$payload', presence: true, prompt: {'title': promptTitle, 'description': promptTitle});
    } on PlatformException catch (e) {
      throw NexusPushAuthException(e.code == 'cancelled' ? 'cancelled' : 'sign_failed', e.message ?? e.code);
    }

    // 4. Register.
    String? pushToken;
    try {
      pushToken = await FirebaseMessaging.instance.getToken();
    } catch (_) {
      NexusLog.warn('push-auth: no FCM token — requests arrive only while the app is open');
    }
    final res = await api.request(
      'POST',
      '/device/enroll',
      silentJwk: silentJwk,
      body: {
        'token': token,
        'platform': Platform.isIOS ? 'ios' : 'android',
        'appId': _identityAppId ?? '',
        'presenceJwk': presenceJwk,
        'silentJwk': silentJwk,
        'presenceProof': presenceProof,
        'attestation': attestation,
        if (pushToken != null) 'push': {'provider': 'fcm', 'token': pushToken},
        'methods': [for (final m in NexusPushAuthMethods.all) m.toJson()],
        'sdkVersion': 'flutter/$nexusFlutterVersion',
        'osVersion': Platform.operatingSystemVersion.split(' ').first,
        'friendlyName': ?friendlyName,
      },
    );
    final f = NexusPushAuthFactor._from((res['factor'] as Map).cast<String, dynamic>());
    st
      ..factorId = f.id
      ..identity = f.identity
      ..channel = (res['factor'] as Map)['channel'] as String?
      ..presenceJkt = pjkt
      ..silentJwk = silentJwk;
    await _save();
    _api = PushAuthApi(st);
    _listenRealtime();
    NexusLog.info('push-auth: enrolled ${f.id} (${f.keyStrength}${f.attested ? ', attested' : ''})');
    return f;
  }

  /// Remove this phone (server + keys). Safe to call when not enrolled.
  Future<void> unenroll() async {
    final st = _state;
    if (st == null) return;
    if (st.enrolled) {
      try {
        await _api!.request('DELETE', '/device/factors/${st.factorId}');
      } catch (e) {
        NexusLog.warn('push-auth: server unenroll failed ($e) — removing local keys anyway');
      }
    }
    await NexusPlatform.instance.pushAuthDeleteKeys(st.prefix);
    st
      ..factorId = null
      ..identity = null
      ..channel = null
      ..silentJwk = null
      ..presenceJkt = null;
    await _save();
  }

  /// Ask Nexus for pending requests now (also done on start and app resume).
  /// Each new one is emitted on [requests].
  Future<List<NexusPushAuthRequest>> checkPending() async {
    if (!isEnrolled) return const [];
    try {
      final res = await _api!.request('GET', '/device/factors/${_state!.factorId}/challenges');
      final list = [for (final c in (res['challenges'] as List? ?? const [])) NexusPushAuthRequest._(this, (c as Map).cast<String, dynamic>())];
      for (final r in list) {
        _emit(r);
      }
      return list;
    } on NexusPushAuthException catch (e) {
      if (e.code == 'factor_inactive') NexusLog.warn('push-auth: this device was removed or locked (${e.reason ?? e.message})');
      return const [];
    }
  }

  /// Fetch one request (signed — this is also the delivery receipt).
  Future<NexusPushAuthRequest?> fetch(String challengeId, {String via = 'pull'}) async {
    if (!isEnrolled) return null;
    final j = await _api!.request('GET', '/device/factors/${_state!.factorId}/challenges/$challengeId?via=$via');
    return NexusPushAuthRequest._(this, j);
  }

  /// Handle a push this app received itself (when it owns FirebaseMessaging
  /// listeners). Returns true when it was a Push Authentication message.
  Future<bool> handleMessage(Map<String, dynamic> data, {String via = 'push'}) async {
    final type = data['type'];
    if (type == 'push_auth_cancel') {
      final cid = data['cid'] as String?;
      if (cid != null) {
        _closed.add(cid);
        await NexusPlatform.instance.pushAuthDismiss(id: cid.hashCode, cid: cid);
      }
      return true;
    }
    if (type != 'push_auth_challenge') return false;
    final cid = data['cid'] as String?;
    if (cid == null || !isEnrolled) return true;
    try {
      final r = await fetch(cid, via: via);
      if (r != null) _emit(r);
    } catch (e) {
      NexusLog.warn('push-auth: could not fetch $cid ($e)');
    }
    return true;
  }

  // ---------------------------------------------------------------------------

  void _emit(NexusPushAuthRequest r) {
    if (!r.isPending) return;
    // Once per request revision (an escalation re-delivers as a new step).
    if ((_seen[r.id] ?? 0) >= r.rev) return;
    _seen[r.id] = r.rev;
    if (!r.interactive) {
      unawaited(answerSilently(r, _api!, _state!));
      return;
    }
    if (!r.isSupported) {
      NexusLog.warn('push-auth: request ${r.id} uses "${r.method}", which this app version can’t show');
      return;
    }
    _requests.add(r);
  }

  Future<NexusPushAuthResult> _respond(NexusPushAuthRequest r, String act, {Map<String, Object?>? response, String? reason, String? promptTitle}) async {
    final api = _api;
    if (api == null || !isEnrolled) throw NexusPushAuthException('not_enrolled', 'This device is not enrolled');
    if (act == 'approve' && !r.isSupported) throw NexusPushAuthException('method_unsupported', 'This app can’t approve "${r.method}"');
    final jws = await buildResponse(api, r.id, r.factorId, r.rev, r.method, r.version, act, r._detailsJson(),
        response: response, reason: reason, presence: r.requiresUserPresence && act == 'approve', promptTitle: promptTitle ?? r.message);
    final res = await api.request('POST', '/device/factors/${r.factorId}/challenges/${r.id}/respond', body: {'response': jws});
    _closed.add(r.id);
    await NexusPlatform.instance.pushAuthDismiss(id: r.id.hashCode, cid: r.id);
    return NexusPushAuthResult._(
      res['status'] as String? ?? 'pending',
      res['reason'] as String?,
      ((res['result'] as Map?)?['code']) as String?,
    );
  }

  void _listenPush() {
    try {
      _subs.add(FirebaseMessaging.onMessage.listen((m) => unawaited(handleMessage(m.data, via: 'push'))));
      _subs.add(FirebaseMessaging.onMessageOpenedApp.listen((m) => unawaited(handleMessage(m.data, via: 'push'))));
      _subs.add(FirebaseMessaging.instance.onTokenRefresh.listen((t) => unawaited(_updatePush(t))));
      unawaited(FirebaseMessaging.instance.getInitialMessage().then((m) {
        if (m != null) unawaited(handleMessage(m.data, via: 'push'));
      }));
    } catch (_) {
      NexusLog.debug('push-auth: Firebase not initialised — realtime + pull only');
    }
  }

  void _listenRealtime() {
    final rt = _realtime;
    final ch = _state?.channel;
    if (rt == null || ch == null) return;
    rt.on(_realtimeEvent, (data) {
      if (data is Map) unawaited(handleMessage(data.cast<String, dynamic>(), via: 'realtime'));
    });
    unawaited(Future.sync(() => rt.join(ch)).catchError((_) => null));
  }

  Future<void> _syncFactor() async {
    String? token;
    try {
      token = await FirebaseMessaging.instance.getToken();
    } catch (_) {}
    try {
      await _api!.request('PATCH', '/device/factors/${_state!.factorId}', body: {
        if (token != null) 'push': {'provider': 'fcm', 'token': token},
        'methods': [for (final m in NexusPushAuthMethods.all) m.toJson()],
        'sdkVersion': 'flutter/$nexusFlutterVersion',
      });
    } catch (e) {
      NexusLog.debug('push-auth: factor sync failed ($e)');
    }
  }

  Future<void> _updatePush(String token) async {
    if (!isEnrolled) return;
    try {
      await _api!.request('PATCH', '/device/factors/${_state!.factorId}', body: {'push': {'provider': 'fcm', 'token': token}});
    } catch (_) {}
  }

  /// App came to the foreground: collect anything a push didn't deliver.
  void onResume() => unawaited(checkPending());

  Future<PushAuthState?> _load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_prefKey);
      return raw == null ? null : PushAuthState.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    final st = _state;
    if (st == null) return;
    await (await SharedPreferences.getInstance()).setString(_prefKey, jsonEncode(st.toJson()));
  }

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _requests.close();
    _closed.close();
    _api?.close();
  }

  static String _weaker(String? a, String? b) {
    const rank = {'software': 0, 'unknown': 0, 'tee': 1, 'secure_enclave': 2, 'strongbox': 2};
    return (rank[a] ?? 0) <= (rank[b] ?? 0) ? (a ?? 'unknown') : (b ?? 'unknown');
  }
}

/// SDK version reported at enrollment.
const nexusFlutterVersion = '1.13.0';

/// Build a signed response (shared by the UI isolate and the background isolate).
Future<String> buildResponse(
  PushAuthApi api,
  String cid,
  String fid,
  int rev,
  String method,
  int version,
  String act,
  Map<String, Object?> details, {
  Map<String, Object?>? response,
  String? reason,
  required bool presence,
  String? promptTitle,
}) async {
  final dh = detailsHash(
    message: details['message'] as String,
    fields: [for (final f in details['fields'] as List) (f as Map).cast<String, String>()],
    context: (details['context'] as Map).cast<String, String>(),
  );
  final header = b64urlJson({'typ': 'nexus-push-auth-response+jwt', 'alg': 'ES256'});
  final payload = b64urlJson({
    'cid': cid,
    'fid': fid,
    'rev': rev,
    'm': method,
    'v': version,
    'act': act,
    'dh': dh,
    'r': ?response,
    'reason': ?reason,
    'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  });
  try {
    return await api.signJws('$header.$payload', presence: presence, prompt: {'title': 'Approve', 'description': promptTitle});
  } on PlatformException catch (e) {
    throw NexusPushAuthException(
      switch (e.code) { 'cancelled' => 'cancelled', 'invalidated' => 'key_invalidated', 'lockout' => 'lockout', _ => 'sign_failed' },
      e.message ?? e.code,
    );
  }
}

/// Answer a silent request: approve with the silent key — unless the app opted
/// out ([NexusConfig.pushAuthSilentApproval] false), then decline silently.
Future<void> answerSilently(NexusPushAuthRequest r, PushAuthApi api, PushAuthState st) async {
  try {
    final jws = await buildResponse(api, r.id, r.factorId, r.rev, r.method, r.version, st.silentApproval ? 'approve' : 'deny', r._detailsJson(),
        presence: false);
    await api.request('POST', '/device/factors/${r.factorId}/challenges/${r.id}/respond', body: {'response': jws});
    NexusLog.info('push-auth: answered silent request ${r.id}');
  } catch (e) {
    NexusLog.warn('push-auth: silent answer failed ($e)');
  }
}

/// Background isolate (app killed / backgrounded): called by the SDK's ONE
/// shared FCM background handler for `push_auth_*` messages. Silent requests
/// are answered here; interactive ones post a notification (Android — iOS
/// shows the APNs alert itself), opening the app to the approval sheet.
@pragma('vm:entry-point')
Future<void> handlePushAuthBackground(Map<String, dynamic> data) async {
  final type = data['type'];
  final cid = data['cid'] as String?;
  if (cid == null) return;
  if (type == 'push_auth_cancel') {
    await NexusPlatform.instance.pushAuthDismiss(id: cid.hashCode, cid: cid);
    return;
  }
  if (type != 'push_auth_challenge') return;
  final PushAuthState? st;
  try {
    final raw = (await SharedPreferences.getInstance()).getString(_prefKey);
    st = raw == null ? null : PushAuthState.fromJson(jsonDecode(raw));
  } catch (_) {
    return;
  }
  if (st == null || !st.enrolled) return;
  final api = PushAuthApi(st);
  try {
    if (data['m'] == 'silent') {
      final j = await api.request('GET', '/device/factors/${st.factorId}/challenges/$cid?via=push');
      final r = NexusPushAuthRequest._(null, j);
      if (r.isPending && !r.interactive) await answerSilently(r, api, st);
      return;
    }
    if (Platform.isAndroid) {
      // Receipt first (the server stops re-pushing), then the notification.
      unawaited(api.request('GET', '/device/factors/${st.factorId}/challenges/$cid?via=push').then((_) => null, onError: (_) => null));
      await NexusPlatform.instance.showNotification(
        id: cid.hashCode,
        title: (data['title'] as String?) ?? 'Approve sign-in?',
        body: (data['body'] as String?) ?? 'Tap to review',
        channelId: 'nexus_push_auth',
        channelName: 'Sign-in approvals',
        payload: jsonEncode({'type': 'push_auth_challenge', 'cid': cid}),
      );
    }
  } catch (e) {
    NexusLog.warn('push-auth: background handling failed ($e)');
  } finally {
    api.close();
  }
}
