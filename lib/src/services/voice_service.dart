import 'dart:async';
import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:permission_handler/permission_handler.dart';

import '../../nexus_platform_interface.dart';
import '../background_dispatch.dart';
import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';
import 'realtime_service.dart';
import '../voice/callkit.dart';
import '../voice/callkit_native.dart';
import '../voice/ios_audio.dart';
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
  AppLifecycleListener? _lifecycle;
  // After we answer, the caller may already have hung up (left the media room),
  // so no remote participant ever appears and the call is stuck "connecting".
  // This ends it if nobody shows up shortly after we join.
  Timer? _connectTimeout;
  static const Duration _connectTimeoutDuration = Duration(seconds: 12);
  String? _answeringSessionId; // guards against double-answering one call
  // Sessions the other side just ended — so a racing answer (pilot hangs up as
  // the client taps answer) doesn't try to join a dead call and hang forever.
  final Set<String> _recentlyEnded = <String>{};

  /// Dismiss the native call UI — Android's self-managed ConnectionService ring
  /// + ongoing notification, or the iOS CallKit call. MUST run on every end path
  /// or a cancelled/ended call stays on screen and answerable. Idempotent: the
  /// native side ignores a call it no longer tracks.
  void _dismissNativeCall(String sessionId) {
    if (_hasNativeCallUi) {
      unawaited(_guard(() => NexusPlatform.instance.voiceEndCall(sessionId)));
    }
  }

  /// Both mobile platforms ship a real native call stack behind the SAME
  /// method-channel contract: a self-managed Telecom ConnectionService on
  /// Android, CallKit + PushKit on iOS. Everything below drives them identically.
  static bool get _hasNativeCallUi => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  void _markEnded(String sessionId) {
    _recentlyEnded.add(sessionId);
    if (_recentlyEnded.length > 50) _recentlyEnded.clear();
  }

  /// How long an outbound call rings unanswered before it auto-ends (no answer).
  static const Duration _ringTimeoutDuration = Duration(seconds: 45);

  String get _identityId => _identity.distinctId ?? _identity.deviceKey;
  String get _deviceId => _identity.deviceKey;

  bool _initialised = false;
  String? _joinedRoom; // the voice:<identity> room we're currently listening on

  /// Turnkey setup — called automatically when `voiceEnabled`. Wires the SDK's
  /// BUILT-IN WebRTC engine + native call UI (CallKit/ConnectionService) and
  /// registers this device for incoming-call push so calls ring even when the
  /// app is killed. Developers do NOT call this.
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;
    if (_engine is NoopVoiceEngine) useEngine(LiveKitVoiceEngine());
    if (_callKit is NoopCallKit) useCallKit(NexusNativeCallKit());
    // Register our OWN native call account so incoming calls ring in the system
    // UI and are answered natively: a self-managed Telecom PhoneAccount on
    // Android, a CXProvider + PushKit VoIP registry on iOS. One contract, one
    // Dart code path.
    if (_hasNativeCallUi) {
      unawaited(NexusPlatform.instance.voiceRegisterAccount());
      // Answer/decline taken in the NATIVE call UI (Android's notification /
      // lock-screen ring, iOS's CallKit screen). On answer, connect media in
      // THIS (main) engine — the proven path on both platforms.
      NexusPlatform.instance.onNativeCallEvent((action, callId) {
        NexusLog.info('voice: native call action=$action call=$callId');
        if (action == 'answer') {
          unawaited(answer(callId));
        } else if (action == 'reject' || action == 'disconnect') {
          unawaited(hangup());
        }
      });
    }
    if (!kIsWeb && Platform.isIOS) {
      // CallKit owns the AVAudioSession: LiveKit must never activate it, and its
      // audio engine may only run inside CallKit's activate/deactivate window.
      unawaited(NexusCallAudio.prepare());
      NexusPlatform.instance.onNativeCallAudioSession(
        (active) => unawaited(NexusCallAudio.setActive(active)),
      );
      // The ring itself is raised natively from the APNs VoIP payload, before
      // Dart wakes up. This is that same payload — so the call state, the caller
      // name and a decline-before-answer all behave exactly as on Android.
      NexusPlatform.instance.onNativeVoicePush((data) {
        if (data['type'] == 'cancel_call') {
          // Native already turned the ring into a missed call — reconcile state.
          _onRemoteEnd(data, VoiceCallState.cancelled, 'cancelled');
        } else {
          unawaited(handleIncomingPush(data, alreadyRinging: true));
        }
      });
      // PushKit hands us the VoIP token asynchronously (and rotates it) —
      // register it the moment it lands so a killed app can be rung.
      NexusPlatform.instance.onNativeVoipToken((t) => unawaited(registerPushToken(voipToken: t)));
    }
    _listenForIncoming();
    // Mic permission MUST already be granted BEFORE an incoming call arrives: a
    // call is answered from a killed/background/cold-launch context where the OS
    // will NOT show a runtime permission dialog, so requesting it at answer time
    // silently fails and the callee never joins audio (the caller sees "no
    // answer"). Pre-warm it now — we're in the foreground at startup, the one
    // moment the dialog can actually appear. WhatsApp does the same up front.
    unawaited(_prewarmMic());
    // …and again whenever the app comes to the foreground, which is the first
    // moment a call answered from a background launch can still get the mic.
    try {
      _lifecycle = AppLifecycleListener(onResume: () => unawaited(_prewarmMic()));
    } catch (e) {
      NexusLog.debug('voice: lifecycle listener unavailable: $e');
    }
    // A cold launch driven by ACCEPTING a call in the native UI needs no polling:
    // the platform channel buffers a native "answer" raised before the listener
    // above attached and replays it the instant it does — on both platforms.
    unawaited(_registerDevice());
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
    _joinIdentityRoom();
  }

  /// Listen on `voice:<current identity>`, leaving any room we joined for a
  /// previous identity. The socket-level `on(...)` handlers are registered once
  /// (in [_listenForIncoming]) and stay valid across re-joins.
  void _joinIdentityRoom() {
    final room = 'voice:$_identityId';
    if (_joinedRoom == room) return;
    final previous = _joinedRoom;
    _joinedRoom = room;
    if (previous != null) unawaited(_realtime.leave(previous));
    unawaited(_realtime.join(room));
  }

  /// Re-bind voice to the CURRENT identity — MUST be called after
  /// `identify()`/`reset()`. Voice initialises at app start (before login), so it
  /// first binds to `voice:<deviceKey>`; without re-binding, an identified user
  /// keeps listening on the device room and never rings on `voice:<distinctId>`.
  /// Re-joins the correct room and re-registers the push device under the new id.
  Future<void> rebindIdentity() async {
    if (!_initialised) return;
    _joinIdentityRoom();
    await _registerDevice();
  }

  /// End the current call in response to a remote status event (the other party
  /// declined / was busy / cancelled) — only if it targets the call we're on.
  void _onRemoteEnd(dynamic data, VoiceCallState state, String reason) {
    if (data is! Map) return;
    final sid = (data['sessionId'] ?? data['session_id']) as String?;
    if (sid == null) return;
    // The OTHER side ended it — the call must never stay ringing/answerable, even
    // if we haven't tracked it in `current` yet (killed/racing). Remember it so a
    // racing answer bails, then clear the native UI.
    _markEnded(sid);
    final call = current.value;
    if (reason == 'cancelled') {
      // Caller gave up before we answered → leave a native "Missed call".
      final from = (data['from'] ?? data['callerNumber'] ?? call?.remoteAddress ?? '').toString();
      final name = (data['callerName'] ?? call?.remoteName) as String?;
      if (_hasNativeCallUi) {
        unawaited(_guard(() =>
            NexusPlatform.instance.voiceMissedCall(callId: sid, from: from, displayName: name)));
      } else {
        _dismissNativeCall(sid);
      }
    } else {
      _dismissNativeCall(sid); // declined/busy → just clear it
    }
    if (call == null || call.sessionId != sid || call.state.isTerminal) return;
    NexusLog.info('voice: remote $reason for ${call.sessionId}');
    _ringTimeout?.cancel();
    unawaited(_guard(_engine.disconnect));
    // Clean up our own leg so the control-plane session ends promptly.
    if (call.legId != null) {
      unawaited(_post('/partner/voice/legs/hangup', {'legId': call.legId, 'reason': reason}));
    }
    unawaited(_guard(() => _callKit.reportEnded(call.sessionId))); // iOS native UI
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
    final previous = _callKit;
    if (previous is NexusNativeCallKit) previous.dispose();
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

  /// Request the microphone permission a voice call needs, returning whether it
  /// is granted. Call this from your onboarding (a foreground moment with UI
  /// context) so an incoming call answered later from a killed/background state
  /// — where no permission dialog can be shown — already has audio access. The
  /// SDK also pre-warms it on voice init, but calling it during onboarding with
  /// your own rationale is the best UX.
  Future<bool> ensurePermissions() => _ensureMicPermission();

  /// A call has NO audio without microphone access, and WebRTC's getUserMedia
  /// fails with NotAllowedError if it isn't granted. Request it (turnkey) before
  /// joining any media room.
  Future<bool> _ensureMicPermission({bool allowPrompt = true}) async {
    try {
      // Ask the OS directly first. `permission_handler` cannot express what we
      // need on iOS: it reports "never asked" as denied, and returns
      // `permanentlyDenied` for ANY request that comes back false — including one
      // made from the background, where iOS presents no dialog and refuses
      // immediately WITHOUT recording a denial. Treating that as a permanent
      // refusal would give up on a permission the user has never even seen.
      final native = await NexusPlatform.instance.micPermissionStatus();
      if (native != null && native != 'granted') {
        NexusLog.info('voice: microphone status=$native (prompt ${allowPrompt ? 'allowed' : 'suppressed'})');
      }
      if (native == 'granted') return _micResult(true);
      if (native == 'missing_usage_description') {
        NexusLog.error('voice: NSMicrophoneUsageDescription is MISSING from the app\'s '
            'Info.plist. iOS TERMINATES the app (TCC privacy violation) the instant a '
            'call opens the microphone, so the SDK is holding the mic shut: calls '
            'connect and you can hear the other party, but this device cannot '
            'transmit. Add NSMicrophoneUsageDescription to ios/Runner/Info.plist.');
        return _micResult(false);
      }
      if (native == 'denied' || native == 'restricted') {
        NexusLog.warn('voice: microphone permission is blocked in system settings — '
            'the other party will not hear this device. The OS will not ask again; '
            'send the user to Settings with Nexus.instance.voice.openMicrophoneSettings().');
        return _micResult(false);
      }

      if (native == 'undetermined') {
        if (!allowPrompt) return _micResult(false);
        // A dialog can only appear in the FOREGROUND — and a VoIP push waking a
        // killed app is exactly a background launch. The native side refuses to
        // ask there rather than burning the one-shot prompt on a request iOS
        // cannot present; [_prewarmMic] retries on the next foreground.
        final granted = await NexusPlatform.instance.micRequestPermission();
        if (granted != null) {
          if (!granted) {
            NexusLog.warn('voice: microphone not granted — the other party will not hear '
                'this device. If the user refused, iOS will not ask again: send them to '
                'Settings with Nexus.instance.voice.openMicrophoneSettings().');
          }
          return _micResult(granted);
        }
        // Native request unavailable (Android) — fall through to permission_handler.
      }

      var status = await Permission.microphone.status;
      if (status.isGranted) return _micResult(true);
      if (!allowPrompt) return _micResult(false);
      // A permission dialog can only appear in the FOREGROUND — and a VoIP push
      // waking a killed app is exactly a background launch. Asking there returns
      // an instant refusal that means nothing. Defer to the next foreground,
      // where [_prewarmMic] retries.
      if (!await NexusPlatform.instance.appIsForeground()) {
        NexusLog.info('voice: microphone request deferred — the app is in the background '
            '(no dialog can be shown); it will be requested on the next foreground');
        return _micResult(false);
      }
      status = await Permission.microphone.request();
      if (!status.isGranted) {
        NexusLog.warn('voice: microphone permission $status — cannot join call audio');
      }
      return _micResult(status.isGranted);
    } catch (e) {
      NexusLog.warn('voice: mic permission check failed: $e');
      return true; // don't hard-block on a plugin error — let getUserMedia try
    }
  }

  /// Publish the outcome of a permission check to the audio layer, which gates
  /// the media engine's INPUT side on it. Returns [granted] so checks can
  /// `return _micResult(...)` directly.
  bool _micResult(bool granted) {
    unawaited(NexusCallAudio.setMicrophoneGranted(granted));
    return granted;
  }

  /// Ask for the microphone at the first moment the OS can actually show the
  /// dialog. Runs on voice init and again on every foreground, so a call that
  /// woke the app in the background (where asking is impossible) still ends up
  /// with permission the next time the user opens the app. No-op once granted.
  Future<void> _prewarmMic() async {
    if (await NexusPlatform.instance.micPermissionStatus() == 'granted') {
      await _recoverMicForLiveCall();
      return;
    }
    if (await _ensureMicPermission()) await _recoverMicForLiveCall();
  }

  /// Microphone access arrived while a call was ALREADY up — the classic case
  /// being a call answered from a background launch (where no dialog could be
  /// shown) whose user then opened the app and granted it. Open the mic on the
  /// live call rather than leaving it one-way until the next one. Respects a
  /// deliberate mute.
  Future<void> _recoverMicForLiveCall() async {
    final call = current.value;
    if (call == null || !call.state.isActive || call.muted) return;
    NexusLog.info('voice: microphone granted mid-call — opening audio for ${call.sessionId}');
    await NexusCallAudio.setMicrophoneGranted(true); // re-open the engine's input side
    await _guard(() => _engine.setMuted(false));
  }

  /// Open this app's OS settings page so the user can grant the microphone after
  /// a permanent denial — iOS never re-prompts once the user has refused, so this
  /// is the only way back. Returns true if the settings page was opened.
  Future<bool> openMicrophoneSettings() async {
    try {
      return await openAppSettings();
    } catch (e) {
      NexusLog.warn('voice: could not open app settings: $e');
      return false;
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
      // On ANDROID we deliberately do NOT start a native outgoing call: a
      // self-managed outgoing ConnectionService can auto-end and echo back an
      // "ended" event that would tear down a healthy call, and a foreground
      // outbound call is driven by the app's own UI + the media engine.
      // On iOS the opposite is true and mandatory: CallKit only activates the
      // audio session for a call it knows about, so an unreported outbound call
      // would connect with no audio at all.
      if (!kIsWeb && Platform.isIOS) {
        unawaited(_guard(() => _callKit.reportOutgoing(
              callId: sessionId,
              handle: to,
              displayName: displayName ?? callerDisplayName,
            )));
      }

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
  Future<void> handleIncomingPush(Map<String, dynamic> data, {bool alreadyRinging = false}) async {
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
    // On iOS the VoIP push already raised the CallKit ring natively before Dart
    // woke up — reporting the same call again would be rejected as a duplicate.
    if (alreadyRinging) return;
    if (_hasNativeCallUi) {
      // Ring in the SYSTEM call UI via our own native stack (ConnectionService on
      // Android, CallKit on iOS) — answered natively, no app launch required.
      await _guard(() => NexusPlatform.instance.voiceReportIncoming(
            callId: sessionId,
            from: from,
            displayName: name,
          ));
    } else {
      await _guard(() => _callKit.reportIncoming(callId: sessionId, handle: from, displayName: name));
    }
  }

  /// Answer the current inbound call — join as a WebRTC leg.
  Future<void> answer([String? sessionId]) async {
    var call = current.value;
    // The other side ended it just as we answered — don't join a dead session
    // (that hangs on "connecting"); make sure the native UI is gone and bail.
    final targetSid = sessionId ?? call?.sessionId;
    if (targetSid != null && _recentlyEnded.contains(targetSid)) {
      NexusLog.info('voice: answer ignored — $targetSid already ended by remote');
      _dismissNativeCall(targetSid);
      return;
    }
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
    // Do NOT prompt here: answering happens from the system call UI, often in a
    // background launch where the dialog cannot appear and the answer is an
    // instant meaningless refusal.
    if (!await _ensureMicPermission(allowPrompt: false)) {
      if (!kIsWeb && Platform.isIOS) {
        // iOS: the user just accepted this call on the CallKit screen. Failing it
        // over a permission we were never able to ask for would drop a live call,
        // so join anyway — LiveKit opens the mic the moment access is granted,
        // and the call is audible in the meantime in the other direction.
        NexusLog.error('voice: answering WITHOUT confirmed microphone access — the caller '
            'may not hear this device. Call Nexus.instance.voice.ensurePermissions() '
            'during onboarding so the prompt happens while the app is open.');
      } else {
        _fail(call.sessionId, 'microphone_denied');
        return;
      }
    }
    try {
      _set(call.copyWith(state: VoiceCallState.connecting));
      final myLeg = await _post('/partner/voice/legs', {
        'sessionId': call.sessionId,
        'role': 'callee',
        'endpointType': 'webrtc',
        'direction': 'inbound',
        'identityId': _identityId, // tag the media leg with WHO answered
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
      // If the caller already hung up, no remote will ever join this room — don't
      // sit on "connecting" forever. End it if nobody appears shortly.
      _armConnectTimeout(sid);
    } catch (e) {
      NexusLog.error('voice.answer failed: $e');
      _fail(call.sessionId, 'error');
    }
  }

  /// After answering, end the call if it never actually connects (no remote
  /// participant appears — the caller left the room before we joined).
  void _armConnectTimeout(String sessionId) {
    _connectTimeout?.cancel();
    _connectTimeout = Timer(_connectTimeoutDuration, () {
      final call = current.value;
      if (call == null || call.sessionId != sessionId) return;
      // Already connected or already ended → nothing to do.
      if (call.state == VoiceCallState.connected ||
          call.state == VoiceCallState.onHold ||
          call.state.isTerminal) {
        return;
      }
      NexusLog.info('voice: connect timeout — caller left before we joined ($sessionId)');
      unawaited(_guard(_engine.disconnect));
      if (call.legId != null) {
        unawaited(_post('/partner/voice/legs/hangup', {'legId': call.legId, 'reason': 'remote_left'}));
      }
      _markEnded(sessionId);
      unawaited(_guard(() => _callKit.reportEnded(sessionId)));
      _dismissNativeCall(sessionId);
      _set(call.copyWith(state: VoiceCallState.ended, endReason: 'remote_left'));
      _teardown();
    });
  }

  /// Decline the current inbound call.
  Future<void> decline() async {
    final call = current.value;
    if (call == null) return;
    await _guard(() => _callKit.reportEnded(call.sessionId));
    _dismissNativeCall(call.sessionId);
    _markEnded(call.sessionId);
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
    _dismissNativeCall(call.sessionId);
    _markEnded(call.sessionId);
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
      _connectTimeout?.cancel(); // remote is here — we really connected
      if (call.state != VoiceCallState.connected && call.state != VoiceCallState.onHold) {
        _set(call.copyWith(state: VoiceCallState.connected, connectedAt: call.connectedAt ?? DateTime.now()));
        unawaited(_guard(() => _callKit.reportConnected(call.sessionId)));
      }
    } else if (call.connectedAt != null && call.state.isActive) {
      // The other party left an established call → end it.
      _markEnded(call.sessionId);
      _set(call.copyWith(state: VoiceCallState.ended, endReason: 'remote_left'));
      unawaited(_guard(_engine.disconnect));
      unawaited(_guard(() => _callKit.reportEnded(call.sessionId)));
      _dismissNativeCall(call.sessionId);
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
    if (sessionId != null) {
      _markEnded(sessionId);
      unawaited(_guard(() => _callKit.reportEnded(sessionId)));
      _dismissNativeCall(sessionId); // clear the native ring/ongoing UI too
    }
    _teardown();
    return null;
  }

  void _teardown() {
    _answeringSessionId = null;
    _ringTimeout?.cancel();
    _ringTimeout = null;
    _connectTimeout?.cancel();
    _connectTimeout = null;
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
    _lifecycle?.dispose();
    _lifecycle = null;
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
