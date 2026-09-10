import 'dart:async';
import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../background_dispatch.dart';
import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';
import 'realtime_service.dart';
import '../voice/callkit.dart';
import '../voice/callkit_native.dart';
import '../voice/ivr.dart';
import '../voice/livekit_engine.dart';
import '../voice/voice_engine.dart';
import '../voice/voice_models.dart';

/// Nexus Voice — the client calling API. Talks to the Voice control plane
/// (`/partner/voice/*`), drives a pluggable [NexusVoiceEngine] for media and an
/// optional [NexusCallKit] for the native call UI, and exposes the live call as
/// a [ValueListenable]. Follows the SDK rule: it NEVER throws into the app —
/// failures are logged and surface as a failed/ended call state.
class NexusVoice {
  NexusVoice(this._http, this._identity, this._realtime);

  final NexusHttp _http;
  final NexusIdentity _identity;
  final NexusRealtime _realtime;

  NexusVoiceEngine _engine = NoopVoiceEngine();
  NexusCallKit _callKit = NoopCallKit();

  /// The current call (null when idle). Listen to drive your call UI.
  final ValueNotifier<NexusCall?> current = ValueNotifier<NexusCall?>(null);

  /// The current in-app IVR menu session (null when not in a menu). Drives the
  /// built-in [NexusIvrOverlay]; listen to build your own support-menu UI.
  final ValueNotifier<NexusIvrSession?> ivr = ValueNotifier<NexusIvrSession?>(null);
  final AudioPlayer _ivrAudio = AudioPlayer(); // plays IVR prompt recordings (audioUrl)

  /// Optional hook for IVR prompts returned by DTMF (play/collect instructions).
  void Function(Map<String, dynamic> instruction)? onIvr;

  StreamSubscription<VoiceEngineState>? _engineSub;
  StreamSubscription<int>? _remoteSub;
  StreamSubscription<CallQualitySample>? _qualitySub;
  StreamSubscription<CallKitAction>? _callKitSub;
  Timer? _presence;
  Timer? _ringTimeout;
  String? _answeringSessionId; // guards against double-answering one call

  /// How long an outbound call rings unanswered before it auto-ends (no answer).
  static const Duration _ringTimeoutDuration = Duration(seconds: 45);

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
    _listenForIncoming();
    // If the app was cold-launched / foregrounded by the user ACCEPTING an
    // incoming call from the native UI, join it NOW. This is time-critical, so
    // it must NOT wait behind device registration (whose token-retry loop can
    // block for tens of seconds — long enough for the caller to give up).
    unawaited(_answerColdLaunchAccept());
    unawaited(_registerDevice());
  }

  /// After a cold launch from a native "accept", the accepted flag may not be
  /// visible the very instant we start — poll briefly, then answer.
  Future<void> _answerColdLaunchAccept() async {
    final ck = _callKit;
    if (ck is! CallKitNativeHandler) return;
    NexusLog.info('voice: checking for a cold-launch accepted call…');
    for (var i = 0; i < 12; i++) {
      final accepted = await ck.acceptedCallId();
      if (accepted != null) {
        NexusLog.info('voice: cold-launch accepted call $accepted — answering');
        await answer(accepted);
        return;
      }
      // Stop polling once a live call is already being handled by the event path.
      final c = current.value;
      if (c != null && c.legId != null && c.state.isActive) return;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    NexusLog.warn('voice: no cold-launch accepted call found after polling');
  }

  bool _fcmWired = false;

  /// Auto-handle incoming-call FCM pushes so the app needs ZERO push code:
  /// - foreground: show the call via [handleIncomingPush];
  /// - background/killed: the top-level [nexusVoiceFirebaseBackgroundHandler]
  ///   shows the native ringer from the background isolate.
  /// Registered once, as soon as Firebase is ready.
  void _wireFcmHandlers() {
    if (_fcmWired) return;
    try {
      // Single shared background handler — Voice + Push MUST NOT each register
      // their own (Firebase keeps only the last one, dropping the other).
      ensureNexusBackgroundHandler();
      FirebaseMessaging.onMessage.listen((m) {
        if (m.data['type'] == 'incoming_call') {
          unawaited(handleIncomingPush(Map<String, dynamic>.from(m.data)));
        }
      });
      // The user tapped the call notification (app was backgrounded/killed and the
      // OS showed the high-priority call notification) — open the call screen.
      FirebaseMessaging.onMessageOpenedApp.listen((m) {
        if (m.data['type'] == 'incoming_call') {
          unawaited(handleIncomingPush(Map<String, dynamic>.from(m.data)));
        }
      });
      FirebaseMessaging.instance.getInitialMessage().then((m) {
        if (m != null && m.data['type'] == 'incoming_call') {
          unawaited(handleIncomingPush(Map<String, dynamic>.from(m.data)));
        }
      });
      FirebaseMessaging.instance.onTokenRefresh.listen((t) => unawaited(registerPushToken(fcmToken: t)));
      _fcmWired = true;
      NexusLog.debug('voice: FCM incoming-call handlers wired');
    } catch (e) {
      NexusLog.warn('voice: FCM handler wiring failed: $e');
    }
  }

  /// Ring instantly when the app is OPEN: listen on the identity's realtime room
  /// for `call.incoming`. The same room also carries live status for calls we're
  /// part of — a callee's decline reaches the caller (`call.rejected`/`call.busy`)
  /// and a caller's cancel dismisses the callee's ring (`call.cancelled`) — so
  /// neither side is left hanging until a timeout. (Killed-app ringing uses push.)
  void _listenForIncoming() {
    _realtime.connect(); // idempotent — ensure the socket is up for voice
    _realtime.on('call.incoming', (dynamic data) {
      if (data is Map) unawaited(handleIncomingPush(Map<String, dynamic>.from(data)));
    });
    _realtime.on('call.rejected', (dynamic d) => _onRemoteEnd(d, VoiceCallState.rejected, 'declined'));
    _realtime.on('call.busy', (dynamic d) => _onRemoteEnd(d, VoiceCallState.rejected, 'busy'));
    _realtime.on('call.cancelled', (dynamic d) => _onRemoteEnd(d, VoiceCallState.cancelled, 'cancelled'));
    _realtime.join('voice:$_identityId');
  }

  /// End the current call in response to a remote status event (the other party
  /// declined / was busy / cancelled) — only if it targets the call we're on.
  void _onRemoteEnd(dynamic data, VoiceCallState state, String reason) {
    if (data is! Map) return;
    final sid = (data['sessionId'] ?? data['session_id']) as String?;
    final call = current.value;
    if (call == null || sid == null || call.sessionId != sid || call.state.isTerminal) return;
    NexusLog.info('voice: remote $reason for ${call.sessionId}');
    _ringTimeout?.cancel();
    unawaited(_guard(_engine.disconnect));
    // Clean up our own leg so the control-plane session ends promptly.
    if (call.legId != null) {
      unawaited(_post('/partner/voice/legs/hangup', {'legId': call.legId, 'reason': reason}));
    }
    unawaited(_guard(() => _callKit.reportEnded(call.sessionId))); // dismiss native ringer/ongoing UI
    _set(call.copyWith(state: state, endReason: reason));
    _teardown();
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
  /// the app is backgrounded/killed. Firebase often initialises AFTER Nexus.init,
  /// so the FCM token isn't ready at first — we update when it rotates/arrives and
  /// retry for a short while.
  Future<void> _registerDevice() async {
    // Retry until the PLATFORM-APPROPRIATE token is available (Firebase often
    // initialises after Nexus.init, so the FCM token isn't ready immediately).
    for (var i = 0; i < 12; i++) {
      if (await registerPushToken()) return;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    NexusLog.warn('voice: no push token yet — background/killed incoming calls '
        'will not ring until a token registers (call registerPushToken from your app).');
  }

  /// Register this device's push tokens (iOS VoIP / Android FCM) for incoming
  /// calls when the app is backgrounded/killed. The SDK does this automatically;
  /// call it yourself with a token if your app owns FCM/OneSignal and wants to
  /// hand the SDK the exact token. Returns true once a token was registered.
  Future<bool> registerPushToken({String? voipToken, String? fcmToken}) async {
    try {
      final ios = Platform.isIOS;
      // iOS rings via APNs VoIP (PushKit); Android via FCM. Only use the token
      // that platform actually uses, and treat an empty token as absent.
      var voip = ios ? (voipToken ?? await _callKit.voipToken()) : null;
      if (voip != null && voip.isEmpty) voip = null;
      var fcm = fcmToken;
      if (fcm == null && !ios) {
        try {
          fcm = await FirebaseMessaging.instance.getToken();
          _wireFcmHandlers(); // firebase is ready — auto-handle incoming pushes
        } catch (_) {/* firebase not ready — retry */}
      }
      if (fcm != null && fcm.isEmpty) fcm = null;

      // Not done until we have the platform's real token → keep retrying.
      final haveToken = ios ? voip != null : fcm != null;
      if (!haveToken) return false;

      await _post('/partner/voice/devices', {
        'identityId': _identityId,
        'deviceId': _deviceId,
        'platform': ios ? 'ios' : (Platform.isAndroid ? 'android' : 'other'),
        'voipToken': ?voip,
        'fcmToken': ?fcm,
      });
      NexusLog.info('voice: device registered for incoming push (fcm=${fcm != null}, voip=${voip != null})');
      return true;
    } catch (e) {
      NexusLog.warn('voice: device registration failed: $e');
      return false;
    }
  }

  /// A call has NO audio without microphone access, and WebRTC's getUserMedia
  /// fails with NotAllowedError if it isn't granted. Request it (turnkey) before
  /// joining any media room.
  Future<bool> _ensureMicPermission() async {
    try {
      var status = await Permission.microphone.status;
      if (!status.isGranted) status = await Permission.microphone.request();
      if (!status.isGranted) {
        NexusLog.warn('voice: microphone permission $status — cannot join call audio');
      }
      return status.isGranted;
    } catch (e) {
      NexusLog.warn('voice: mic permission check failed: $e');
      return true; // don't hard-block on a plugin error — let getUserMedia try
    }
  }

  void _bindEngine() {
    _engineSub?.cancel();
    _remoteSub?.cancel();
    _qualitySub?.cancel();
    _engineSub = _engine.states.listen(_onEngineState);
    _remoteSub = _engine.remoteCount.listen(_onRemoteCount);
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
    String? callerDisplayName,
    bool record = false,
    Map<String, dynamic> metadata = const {},
  }) async {
    try {
      if (!await _ensureMicPermission()) return _fail(null, 'microphone_denied');
      // The name the CALLEE sees for us (rings + call screen). Rides in session
      // metadata → the backend puts it in the ring payload as `callerName`.
      final md = <String, dynamic>{
        ...metadata,
        if (callerDisplayName != null && callerDisplayName.isNotEmpty) 'callerName': callerDisplayName,
      };
      final session = await _post('/partner/voice/calls', {
        'direction': 'outbound',
        'recordingMode': record ? 'mixed' : 'disabled',
        if (md.isNotEmpty) 'metadata': md,
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

      // 1) This device's WebRTC leg → join the media room. Carry our identity so
      // the control plane can tell the callee WHO is calling (the ring's `from`).
      final myLeg = await _post('/partner/voice/legs', {
        'sessionId': sessionId,
        'role': 'caller',
        'endpointType': 'webrtc',
        'direction': 'outbound',
        'identityId': _identityId,
      });
      final legId = _id(myLeg?['leg']);
      final token = NexusJoinToken.tryParse(myLeg?['join'] as Map<String, dynamic>?);
      if (myLeg?['error'] != null) {
        NexusLog.warn('voice: backend could not provision media (${myLeg!['error']}) — '
            'is LiveKit configured + reachable from the backend?');
        return _fail(sessionId, myLeg['error'].toString());
      }
      if (legId == null || token == null) return _fail(sessionId, 'join_failed');
      NexusLog.info('voice: joining media room "${token.room}" at ${token.url}');
      _set(current.value!.copyWith(legId: legId, state: VoiceCallState.ringing));
      try {
        await _engine.connect(token);
      } catch (e) {
        NexusLog.error('voice: media connect failed to ${token.url} — $e. '
            'The DEVICE must be able to reach the media server; a private LAN IP is '
            'unreachable over a tunnel / cellular / different Wi-Fi.');
        return _fail(sessionId, 'media_connect_failed');
      }

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
      _armRingTimeout(sessionId); // auto-end if the callee never answers
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
    // Idempotent: the same call can arrive over BOTH realtime and FCM (foreground),
    // or be re-delivered — don't reset an already-live call or re-ring.
    final existing = current.value;
    if (existing != null && existing.sessionId == sessionId && !existing.state.isTerminal) return;
    final from = (data['from'] ?? data['callerNumber'] ?? '') as String;
    final name = data['callerName'] as String?;
    // The backend's callee placeholder leg — lets a decline BEFORE we answer
    // reach the control plane. Replaced by this device's media leg on answer.
    final ringLegId = (data['legId'] ?? data['leg_id']) as String?;
    _set(NexusCall(
      sessionId: sessionId,
      direction: VoiceCallDirection.inbound,
      state: VoiceCallState.ringing,
      remoteAddress: from,
      remoteName: name,
      legId: ringLegId,
      startedAt: DateTime.now(),
    ));
    await _guard(() => _callKit.reportIncoming(callId: sessionId, handle: from, displayName: name));
  }

  /// Answer the current inbound call — join as a WebRTC leg.
  Future<void> answer([String? sessionId]) async {
    var call = current.value;
    // Cold-launch accept: the app was killed and the user accepted from the
    // native UI — reconstruct the inbound call from the session id in the event.
    if (call == null && sessionId != null) {
      call = NexusCall(
        sessionId: sessionId,
        direction: VoiceCallDirection.inbound,
        state: VoiceCallState.connecting,
        startedAt: DateTime.now(),
      );
      _set(call);
    }
    if (call == null || call.direction != VoiceCallDirection.inbound) return;
    // The accept can reach us via BOTH the CallKit event stream and the
    // cold-launch poll — answer each call exactly once, or we create two legs.
    if (_answeringSessionId == call.sessionId) return;
    _answeringSessionId = call.sessionId;
    NexusLog.info('voice: answering call ${call.sessionId}');
    if (!await _ensureMicPermission()) {
      _fail(call.sessionId, 'microphone_denied');
      return;
    }
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
        NexusLog.warn('voice: answer join_failed (leg=$legId token=${token != null}) — ${myLeg?['error']}');
        _fail(call.sessionId, 'join_failed');
        return;
      }
      _set(current.value!.copyWith(legId: legId));
      NexusLog.info('voice: answered — joining media room "${token.room}" at ${token.url}');
      await _engine.connect(token);
      await _post('/partner/voice/legs/answer', {'legId': legId});
      final sid = call.sessionId;
      await _guard(() => _callKit.reportConnected(sid));
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

  // ── In-app IVR (customer-support menu) ─────────────────────────────────────

  /// Open an in-app IVR menu (a visual phone-tree) for [flowId] — e.g. a support
  /// entry point built in the dashboard. The built-in [NexusIvrOverlay] renders
  /// it; the caller taps keys to navigate, and the SDK auto-connects a real call
  /// when the flow routes to an agent. Returns false if the menu couldn't start.
  Future<bool> startIvr(String flowId) async {
    try {
      final res = await _post('/partner/voice/ivr/start', {'flowId': flowId});
      final sid = res?['sessionId'] as String?;
      final inst = res?['instruction'];
      if (sid == null || inst is! Map) return false;
      await _handleIvr(sid, Map<String, dynamic>.from(inst));
      return true;
    } catch (e) {
      NexusLog.warn('voice.startIvr failed: $e');
      return false;
    }
  }

  /// Press a key in the current IVR menu.
  Future<void> pressIvrKey(String digit) async {
    final s = ivr.value;
    if (s == null || s.status != NexusIvrStatus.active) return;
    try {
      final res = await _post('/partner/voice/ivr/input', {'sessionId': s.sessionId, 'digit': digit});
      final inst = res?['instruction'];
      if (inst is Map) await _handleIvr(s.sessionId, Map<String, dynamic>.from(inst));
    } catch (e) {
      NexusLog.warn('voice.pressIvrKey failed: $e');
    }
  }

  /// Dismiss the IVR menu (the user backed out).
  void endIvr() {
    unawaited(_ivrAudio.stop());
    ivr.value = null;
  }

  /// Play an IVR prompt recording and complete when it finishes (or after 30s).
  Future<void> _playPrompt(String url) async {
    try {
      await _ivrAudio.stop();
      final done = Completer<void>();
      final sub = _ivrAudio.onPlayerComplete.listen((_) {
        if (!done.isCompleted) done.complete();
      });
      await _ivrAudio.play(UrlSource(url));
      await done.future.timeout(const Duration(seconds: 30), onTimeout: () {});
      await sub.cancel();
    } catch (e) {
      NexusLog.warn('voice: IVR audio failed ($url): $e');
    }
  }

  Future<void> _advanceIvr(String sessionId) async {
    try {
      final res = await _post('/partner/voice/ivr/advance', {'sessionId': sessionId});
      final inst = res?['instruction'];
      if (inst is Map) await _handleIvr(sessionId, Map<String, dynamic>.from(inst));
    } catch (e) {
      NexusLog.warn('voice.advanceIvr failed: $e');
    }
  }

  Future<void> _handleIvr(String sessionId, Map<String, dynamic> inst) async {
    await _ivrAudio.stop(); // stop the previous prompt before rendering this step
    final audioUrl = inst['audioUrl'] as String?;
    final hasAudio = audioUrl != null && audioUrl.isNotEmpty;
    switch (inst['action'] as String?) {
      case 'play':
        ivr.value = NexusIvrSession(sessionId: sessionId, prompt: inst['text'] as String?);
        // Play the recording (wait for it to finish) or just let the text read.
        if (hasAudio) {
          await _playPrompt(audioUrl);
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 1600));
        }
        if (ivr.value?.sessionId != sessionId) break; // user navigated away meanwhile
        if (inst['hasNext'] == true) {
          await _advanceIvr(sessionId);
        } else {
          ivr.value = ivr.value!.copyWith(status: NexusIvrStatus.ended, endedReason: 'ended');
        }
        break;
      case 'collect':
        ivr.value = NexusIvrSession(
          sessionId: sessionId,
          prompt: inst['text'] as String?,
          awaitingInput: true,
          maxDigits: (inst['maxDigits'] as num?)?.toInt() ?? 1,
        );
        if (hasAudio) unawaited(_playPrompt(audioUrl)); // play the menu prompt; keys work anytime
        break;
      case 'connect':
        ivr.value = NexusIvrSession(sessionId: sessionId, status: NexusIvrStatus.connecting);
        final to = inst['to'] as String?;
        if (to != null) {
          await placeCall(to: to, type: _endpointFrom(inst['endpointType'] as String?));
          ivr.value = null; // the call UI takes over
        } else {
          ivr.value = NexusIvrSession(sessionId: sessionId, status: NexusIvrStatus.ended, endedReason: 'error');
        }
        break;
      case 'no_agents':
        ivr.value = NexusIvrSession(sessionId: sessionId, prompt: 'All agents are busy right now. Please try again later.', status: NexusIvrStatus.ended, endedReason: 'no_agents');
        break;
      case 'voicemail':
        // Voicemail recording needs the media plane's egress + storage (not yet
        // enabled) — surface the prompt and end for now.
        ivr.value = NexusIvrSession(sessionId: sessionId, prompt: (inst['text'] as String?) ?? 'Please try again later.', status: NexusIvrStatus.ended, endedReason: 'voicemail_unavailable');
        break;
      case 'hangup':
      case 'ended':
      default:
        ivr.value = NexusIvrSession(sessionId: sessionId, status: NexusIvrStatus.ended, endedReason: 'ended');
    }
  }

  VoiceEndpointType _endpointFrom(String? s) =>
      s == 'pstn' ? VoiceEndpointType.pstn : s == 'sip' ? VoiceEndpointType.sip : VoiceEndpointType.app;

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

  /// Auto-end an outbound call that is never answered (callee never joins the
  /// media room), so the caller isn't left ringing forever. Cancelled the moment
  /// the remote party connects.
  void _armRingTimeout(String sessionId) {
    _ringTimeout?.cancel();
    _ringTimeout = Timer(_ringTimeoutDuration, () {
      final call = current.value;
      if (call == null || call.sessionId != sessionId) return;
      if (call.connectedAt != null || call.state.isTerminal) return; // answered or already gone
      NexusLog.info('voice: outbound call timed out (no answer)');
      unawaited(_guard(_engine.disconnect));
      if (call.legId != null) {
        unawaited(_post('/partner/voice/legs/hangup', {'legId': call.legId, 'reason': 'no_answer'}));
      }
      unawaited(_guard(() => _callKit.reportEnded(sessionId)));
      _set(call.copyWith(state: VoiceCallState.timeout, endReason: 'no_answer'));
      _teardown();
    });
  }

  // ── Engine + CallKit reactions ───────────────────────────────────────────

  void _onEngineState(VoiceEngineState s) {
    final call = current.value;
    if (call == null) return;
    switch (s) {
      // Our OWN connection to the room is up — but the call is only "connected"
      // once the remote party is present (see _onRemoteCount). So stay ringing.
      case VoiceEngineState.connected:
      case VoiceEngineState.connecting:
        break;
      case VoiceEngineState.reconnecting:
        if (call.state.isActive) _set(call.copyWith(state: VoiceCallState.reconnecting));
        break;
      case VoiceEngineState.failed:
        _fail(call.sessionId, 'media_failed');
        break;
      case VoiceEngineState.disconnected:
        if (call.state.isActive) {
          _set(call.copyWith(state: VoiceCallState.ended, endReason: 'disconnected'));
          unawaited(_guard(() => _callKit.reportEnded(call.sessionId)));
          _teardown();
        }
        break;
    }
  }

  /// The remote party joined (n>0) or left (n==0). This is what makes the call
  /// "connected" — for outbound it means the callee answered; for inbound it
  /// means the caller is there.
  void _onRemoteCount(int n) {
    final call = current.value;
    if (call == null || call.state.isTerminal) return;
    if (n > 0) {
      _ringTimeout?.cancel(); // answered — stop the no-answer timer
      if (call.state != VoiceCallState.connected && call.state != VoiceCallState.onHold) {
        _set(call.copyWith(state: VoiceCallState.connected, connectedAt: call.connectedAt ?? DateTime.now()));
        unawaited(_guard(() => _callKit.reportConnected(call.sessionId)));
      }
    } else if (call.connectedAt != null && call.state.isActive) {
      // The other party left an established call → end it.
      _set(call.copyWith(state: VoiceCallState.ended, endReason: 'remote_left'));
      unawaited(_guard(_engine.disconnect));
      unawaited(_guard(() => _callKit.reportEnded(call.sessionId)));
      _teardown();
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
    NexusLog.info('voice: callkit action ${a.type.name} call=${a.callId}');
    switch (a.type) {
      case CallKitActionType.answer:
        unawaited(answer(a.callId)); // callId == sessionId (cold-launch safe)
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
    _answeringSessionId = null;
    _ringTimeout?.cancel();
    _ringTimeout = null;
    _presence?.cancel();
    _presence = null;
    unawaited(setPresence('ONLINE'));
    // Keep `current` on the terminal state briefly so the call screen can show the
    // outcome, then clear it so the overlay dismisses and the next call is clean.
    final ended = current.value;
    Timer(const Duration(seconds: 2), () {
      if (current.value == ended && (current.value?.state.isTerminal ?? false)) {
        current.value = null;
      }
    });
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
    _remoteSub?.cancel();
    _qualitySub?.cancel();
    _callKitSub?.cancel();
    _presence?.cancel();
    _ringTimeout?.cancel();
    current.dispose();
    ivr.dispose();
    unawaited(_ivrAudio.dispose());
  }
}

/// Top-level Firebase background message handler the SDK registers automatically
/// (must be top-level + vm:entry-point to run in the background isolate). Shows
/// the native incoming-call ringer for Nexus Voice pushes; ignores everything
/// else so it coexists with your other messages.
@pragma('vm:entry-point')
Future<void> nexusVoiceFirebaseBackgroundHandler(RemoteMessage message) async {
  if (message.data['type'] == 'incoming_call') {
    await showNexusIncomingCall(message.data);
  }
}
