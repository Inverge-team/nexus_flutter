import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';
import '../voice/callkit.dart';
import '../voice/callkit_native.dart';
import '../voice/livekit_engine.dart';
import '../voice/voice_engine.dart';
import '../voice/voice_models.dart';

/// Nexus Voice — the client calling API. Talks to the Voice control plane
/// (`/partner/voice/*`), drives a pluggable [NexusVoiceEngine] for media and an
/// optional [NexusCallKit] for the native call UI, and exposes the live call as
/// a [ValueListenable]. Follows the SDK rule: it NEVER throws into the app —
/// failures are logged and surface as a failed/ended call state.
class NexusVoice {
  NexusVoice(this._http, this._identity);

  final NexusHttp _http;
  final NexusIdentity _identity;

  NexusVoiceEngine _engine = NoopVoiceEngine();
  NexusCallKit _callKit = NoopCallKit();

  /// The current call (null when idle). Listen to drive your call UI.
  final ValueNotifier<NexusCall?> current = ValueNotifier<NexusCall?>(null);

  /// Optional hook for IVR prompts returned by DTMF (play/collect instructions).
  void Function(Map<String, dynamic> instruction)? onIvr;

  StreamSubscription<VoiceEngineState>? _engineSub;
  StreamSubscription<CallQualitySample>? _qualitySub;
  StreamSubscription<CallKitAction>? _callKitSub;
  Timer? _presence;

  String get _identityId => _identity.distinctId ?? _identity.deviceKey;
  String get _deviceId => _identity.deviceKey;

  bool _initialised = false;

  /// Turnkey setup — called automatically when `voiceEnabled`. Wires the SDK's
  /// BUILT-IN WebRTC engine + native call UI (CallKit/ConnectionService) and
  /// registers this device for incoming-call push so calls ring even when the
  /// app is killed. Developers do NOT call this.
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;
    if (_engine is NoopVoiceEngine) useEngine(LiveKitVoiceEngine());
    if (_callKit is NoopCallKit) useCallKit(CallKitNativeHandler());
    await _registerDevice();
  }

  /// Advanced override — replace the built-in WebRTC engine.
  void useEngine(NexusVoiceEngine engine) {
    _engine = engine;
    _bindEngine();
  }

  /// Advanced override — replace the built-in native call UI.
  void useCallKit(NexusCallKit callKit) {
    _callKit = callKit;
    _callKitSub?.cancel();
    _callKitSub = _callKit.actions.listen(_onCallKitAction);
  }

  /// Register this device's push tokens so the control plane can ring it when
  /// the app is backgrounded/killed. iOS uses the PushKit VoIP token; Android
  /// uses the FCM token. Best-effort + silent.
  Future<void> _registerDevice() async {
    try {
      final voip = await _callKit.voipToken();
      String? fcm;
      try {
        fcm = await FirebaseMessaging.instance.getToken();
      } catch (_) {/* firebase not set up — Android ring unavailable */}
      final platform = Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'other');
      if (voip == null && fcm == null) return;
      await _post('/partner/voice/devices', {
        'identityId': _identityId,
        'deviceId': _deviceId,
        'platform': platform,
        'voipToken': ?voip,
        'fcmToken': ?fcm,
      });
    } catch (e) {
      NexusLog.warn('voice: device registration failed (incoming-when-killed may not ring): $e');
    }
  }

  void _bindEngine() {
    _engineSub?.cancel();
    _qualitySub?.cancel();
    _engineSub = _engine.states.listen(_onEngineState);
    _qualitySub = _engine.quality.listen(_reportQuality);
  }

  // ── Outbound ───────────────────────────────────────────────────────────────

  /// Place a call to [to] — a Nexus identity (app), a phone number (pstn) or a
  /// SIP URI. This device joins as a WebRTC leg; the control plane dials [to].
  Future<NexusCall?> placeCall({
    required String to,
    VoiceEndpointType type = VoiceEndpointType.app,
    String? callerId,
    String? displayName,
    bool record = false,
    Map<String, dynamic> metadata = const {},
  }) async {
    try {
      final session = await _post('/partner/voice/calls', {
        'direction': 'outbound',
        'recordingMode': record ? 'mixed' : 'disabled',
        if (metadata.isNotEmpty) 'metadata': metadata,
      });
      final sessionId = _id(session?['session']);
      if (sessionId == null) return _fail(null, 'session_create_failed');

      _set(NexusCall(
        sessionId: sessionId,
        direction: VoiceCallDirection.outbound,
        state: VoiceCallState.connecting,
        remoteAddress: to,
        remoteName: displayName,
        startedAt: DateTime.now(),
        metadata: metadata,
      ));
      // NOTE: we deliberately do NOT start a native OUTGOING call here. On Android
      // a self-managed outgoing ConnectionService can auto-end and echo back an
      // "ended" event that would tear down a healthy call; a foreground outbound
      // call is driven by the app's own UI + the media engine. CallKit is used for
      // INCOMING calls (the killed-app ringer), where it is essential.

      // 1) This device's WebRTC leg → join the media room.
      final myLeg = await _post('/partner/voice/legs', {
        'sessionId': sessionId,
        'role': 'caller',
        'endpointType': 'webrtc',
        'direction': 'outbound',
      });
      final legId = _id(myLeg?['leg']);
      final token = NexusJoinToken.tryParse(myLeg?['join'] as Map<String, dynamic>?);
      if (legId == null || token == null) return _fail(sessionId, 'join_failed');
      _set(current.value!.copyWith(legId: legId, state: VoiceCallState.ringing));
      await _engine.connect(token);

      // 2) Dial the remote party (app/pstn/sip).
      final callee = await _post('/partner/voice/legs', {
        'sessionId': sessionId,
        'role': 'callee',
        'endpointType': type.name,
        'direction': 'outbound',
        'address': to,
        'callerId': ?callerId,
        if (type == VoiceEndpointType.app) 'identityId': to,
      });
      if (callee?['error'] != null) return _fail(sessionId, callee!['error'].toString());

      _startPresence();
      return current.value;
    } catch (e) {
      NexusLog.error('voice.placeCall failed: $e');
      return _fail(current.value?.sessionId, 'error');
    }
  }

  // ── Inbound ────────────────────────────────────────────────────────────────

  /// Handle an incoming-call push/data message. Call this from your FCM / VoIP
  /// push handler with the payload the backend sent (`{sessionId, from, ...}`).
  /// Shows the native incoming UI and arms [answer]/[decline].
  Future<void> handleIncomingPush(Map<String, dynamic> data) async {
    final sessionId = (data['sessionId'] ?? data['session_id']) as String?;
    if (sessionId == null) return;
    final from = (data['from'] ?? data['callerNumber'] ?? '') as String;
    final name = data['callerName'] as String?;
    _set(NexusCall(
      sessionId: sessionId,
      direction: VoiceCallDirection.inbound,
      state: VoiceCallState.ringing,
      remoteAddress: from,
      remoteName: name,
      startedAt: DateTime.now(),
    ));
    await _guard(() => _callKit.reportIncoming(callId: sessionId, handle: from, displayName: name));
  }

  /// Answer the current inbound call — join as a WebRTC leg.
  Future<void> answer() async {
    final call = current.value;
    if (call == null || call.direction != VoiceCallDirection.inbound) return;
    try {
      _set(call.copyWith(state: VoiceCallState.connecting));
      final myLeg = await _post('/partner/voice/legs', {
        'sessionId': call.sessionId,
        'role': 'callee',
        'endpointType': 'webrtc',
        'direction': 'inbound',
      });
      final legId = _id(myLeg?['leg']);
      final token = NexusJoinToken.tryParse(myLeg?['join'] as Map<String, dynamic>?);
      if (legId == null || token == null) {
        _fail(call.sessionId, 'join_failed');
        return;
      }
      _set(current.value!.copyWith(legId: legId));
      await _engine.connect(token);
      await _post('/partner/voice/legs/answer', {'legId': legId});
      await _guard(() => _callKit.reportConnected(call.sessionId));
      _startPresence();
    } catch (e) {
      NexusLog.error('voice.answer failed: $e');
      _fail(call.sessionId, 'error');
    }
  }

  /// Decline the current inbound call.
  Future<void> decline() async {
    final call = current.value;
    if (call == null) return;
    await _guard(() => _callKit.reportEnded(call.sessionId));
    if (call.legId != null) {
      await _post('/partner/voice/legs/hangup', {'legId': call.legId, 'reason': 'declined'});
    }
    _set(call.copyWith(state: VoiceCallState.rejected, endReason: 'declined'));
    _teardown();
  }

  // ── In-call controls ─────────────────────────────────────────────────────

  Future<void> hangup() async {
    final call = current.value;
    if (call == null || call.state.isTerminal) return;
    await _guard(_engine.disconnect);
    if (call.legId != null) {
      await _post('/partner/voice/legs/hangup', {'legId': call.legId, 'reason': 'hangup'});
    }
    await _guard(() => _callKit.reportEnded(call.sessionId));
    _set(call.copyWith(state: VoiceCallState.ended, endReason: 'hangup'));
    _teardown();
  }

  Future<void> setMuted(bool muted) async {
    final call = current.value;
    if (call == null) return;
    await _guard(() => _engine.setMuted(muted));
    if (call.legId != null) {
      await _post('/partner/voice/conference/mute', {'legId': call.legId, 'muted': muted});
    }
    _set(call.copyWith(muted: muted));
  }

  Future<void> setSpeakerphone(bool on) async {
    final call = current.value;
    if (call == null) return;
    await _guard(() => _engine.setSpeakerphone(on));
    _set(call.copyWith(speakerphone: on));
  }

  Future<void> setHold(bool held) async {
    final call = current.value;
    if (call == null || call.legId == null) return;
    await _guard(() => _engine.setMuted(held)); // stop sending while held
    await _post('/partner/voice/legs/${held ? 'hold' : 'resume'}', {'legId': call.legId});
    _set(call.copyWith(onHold: held, state: held ? VoiceCallState.onHold : VoiceCallState.connected));
  }

  Future<void> sendDtmf(String digit) async {
    final call = current.value;
    if (call == null || call.legId == null) return;
    await _guard(() => _engine.sendDtmf(digit));
    final res = await _post('/partner/voice/dtmf', {
      'sessionId': call.sessionId,
      'legId': call.legId,
      'digit': digit,
    });
    final ivr = res?['ivr'];
    if (ivr is Map<String, dynamic>) onIvr?.call(ivr);
  }

  // ── Presence ───────────────────────────────────────────────────────────────

  Future<void> setPresence(String status) => _post('/partner/voice/presence', {
        'identityId': _identityId,
        'deviceId': _deviceId,
        'status': status,
      }).then((_) {});

  void _startPresence() {
    _presence?.cancel();
    void beat() => unawaited(setPresence('IN_CALL'));
    beat();
    _presence = Timer.periodic(const Duration(seconds: 30), (_) => beat());
  }

  // ── Engine + CallKit reactions ───────────────────────────────────────────

  void _onEngineState(VoiceEngineState s) {
    final call = current.value;
    if (call == null) return;
    switch (s) {
      case VoiceEngineState.connected:
        if (!call.state.isTerminal) {
          _set(call.copyWith(state: VoiceCallState.connected, connectedAt: call.connectedAt ?? DateTime.now()));
          unawaited(_guard(() => _callKit.reportConnected(call.sessionId)));
        }
        break;
      case VoiceEngineState.reconnecting:
        _set(call.copyWith(state: VoiceCallState.reconnecting));
        break;
      case VoiceEngineState.failed:
        _fail(call.sessionId, 'media_failed');
        break;
      case VoiceEngineState.disconnected:
        if (call.state.isActive) {
          _set(call.copyWith(state: VoiceCallState.ended, endReason: 'disconnected'));
          _teardown();
        }
        break;
      case VoiceEngineState.connecting:
        break;
    }
  }

  void _reportQuality(CallQualitySample q) {
    final call = current.value;
    if (call == null) return;
    _set(call.copyWith(quality: q));
    unawaited(_post('/partner/voice/quality', {
      'sessionId': call.sessionId,
      if (call.legId != null) 'legId': call.legId,
      ...q.toJson(),
    }));
  }

  void _onCallKitAction(CallKitAction a) {
    switch (a.type) {
      case CallKitActionType.answer:
        unawaited(answer());
        break;
      case CallKitActionType.decline:
        unawaited(decline());
        break;
      case CallKitActionType.end:
        unawaited(hangup());
        break;
      case CallKitActionType.muted:
        unawaited(setMuted(a.value == true));
        break;
      case CallKitActionType.hold:
        unawaited(setHold(a.value == true));
        break;
      case CallKitActionType.dtmf:
        if (a.value is String) unawaited(sendDtmf(a.value as String));
        break;
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _post(String path, Map<String, Object?> body) => _http.post(path, body);

  void _set(NexusCall call) => current.value = call;

  NexusCall? _fail(String? sessionId, String reason) {
    final call = current.value;
    if (call != null && call.sessionId == sessionId) {
      _set(call.copyWith(state: VoiceCallState.failed, endReason: reason));
    }
    unawaited(_guard(_engine.disconnect));
    if (sessionId != null) unawaited(_guard(() => _callKit.reportEnded(sessionId)));
    _teardown();
    return null;
  }

  void _teardown() {
    _presence?.cancel();
    _presence = null;
    unawaited(setPresence('ONLINE'));
    // Keep `current` on the terminal state briefly so UIs can show the outcome;
    // the app clears it or the next call replaces it.
  }

  Future<void> _guard(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      NexusLog.warn('voice: ignored engine/callkit error: $e');
    }
  }

  String? _id(Object? obj) => obj is Map && obj['id'] is String ? obj['id'] as String : null;

  void dispose() {
    _engineSub?.cancel();
    _qualitySub?.cancel();
    _callKitSub?.cancel();
    _presence?.cancel();
    current.dispose();
  }
}
