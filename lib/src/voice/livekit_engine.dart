import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;

import '../logging.dart';
import 'ios_audio.dart';
import 'voice_engine.dart';
import 'voice_models.dart';

/// The SDK's BUILT-IN WebRTC media engine (LiveKit). Registered automatically
/// when `voiceEnabled` — developers never wire this. Handles mic capture,
/// playback, speaker routing, reconnection, and emits connection-quality-derived
/// samples. All calls are guarded; a media failure never escapes.
class LiveKitVoiceEngine implements NexusVoiceEngine {
  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _listener;
  final _states = StreamController<VoiceEngineState>.broadcast();
  final _quality = StreamController<CallQualitySample>.broadcast();
  final _remote = StreamController<int>.broadcast();

  @override
  Stream<VoiceEngineState> get states => _states.stream;
  @override
  Stream<int> get remoteCount => _remote.stream;
  @override
  Stream<CallQualitySample> get quality => _quality.stream;

  @override
  Future<void> connect(NexusJoinToken token) async {
    await disconnect();
    _states.add(VoiceEngineState.connecting);
    final room = lk.Room(
      roomOptions: const lk.RoomOptions(adaptiveStream: true, dynacast: true),
    );
    final listener = room.createListener();
    void emitRemote() => _remote.add(room.remoteParticipants.length);
    listener
      ..on<lk.RoomConnectedEvent>((_) {
        _states.add(VoiceEngineState.connected);
        emitRemote();
      })
      ..on<lk.RoomReconnectingEvent>((_) => _states.add(VoiceEngineState.reconnecting))
      ..on<lk.RoomReconnectedEvent>((_) => _states.add(VoiceEngineState.connected))
      ..on<lk.RoomDisconnectedEvent>((_) => _states.add(VoiceEngineState.disconnected))
      // Remote party joining/leaving is what makes the CALL connected/ended.
      ..on<lk.ParticipantConnectedEvent>((_) => emitRemote())
      ..on<lk.ParticipantDisconnectedEvent>((_) => emitRemote())
      ..on<lk.ParticipantConnectionQualityUpdatedEvent>((e) {
        // Emit a sample only for our own participant's quality.
        if (e.participant == room.localParticipant) {
          _quality.add(_sampleFor(e.connectionQuality));
        }
      });
    _room = room;
    _listener = listener;
    await room.connect(token.url, token.token);
    // The WebRTC audio device module only exists once a room does, so this is the
    // first moment the iOS CallKit audio gate can actually be applied (see
    // [NexusCallAudio]). No-op off iOS.
    await NexusCallAudio.applyPending();
    if (NexusCallAudio.microphoneAvailable) {
      try {
        await room.localParticipant?.setMicrophoneEnabled(true);
      } catch (e) {
        // Do NOT fail the call over it: the room is already connected, so the
        // user can still HEAR the other party, and the mic opens as soon as
        // access is granted (the voice service retries on the next foreground).
        NexusLog.error('livekit: microphone could not be opened ($e) — the call is '
            'connected but this device is not transmitting. Grant microphone access '
            '(Nexus.instance.voice.openMicrophoneSettings()).');
      }
    } else {
      // Deliberately not even attempted: on iOS, opening the mic without
      // authorization terminates the app via TCC rather than throwing.
      NexusLog.error('livekit: joining RECEIVE-ONLY — no microphone access. The other '
          'party will not hear this device until it is granted.');
    }
    emitRemote();
  }

  @override
  Future<void> disconnect() async {
    try {
      await _listener?.dispose();
      await _room?.disconnect();
      await _room?.dispose();
    } catch (e) {
      NexusLog.warn('livekit: disconnect ignored error: $e');
    }
    _listener = null;
    _room = null;
    NexusCallAudio.reset(); // the audio gate belongs to a live session only
  }

  @override
  Future<void> setMuted(bool muted) async {
    await _room?.localParticipant?.setMicrophoneEnabled(!muted);
  }

  @override
  Future<void> setSpeakerphone(bool on) async {
    // ignore: deprecated_member_use
    await lk.Hardware.instance.setSpeakerphoneOn(on);
  }

  @override
  Future<void> sendDtmf(String digit) async {
    // DTMF to PSTN/SIP legs is injected server-side via the control-plane /dtmf
    // endpoint (RFC 4733 / SIP INFO at the SIP bridge), so the engine no-ops.
  }

  CallQualitySample _sampleFor(lk.ConnectionQuality q) {
    switch (q) {
      case lk.ConnectionQuality.excellent:
        return const CallQualitySample(mos: 4.4, candidateType: null);
      case lk.ConnectionQuality.good:
        return const CallQualitySample(mos: 4.0);
      case lk.ConnectionQuality.poor:
        return const CallQualitySample(mos: 3.0);
      case lk.ConnectionQuality.lost:
        return const CallQualitySample(mos: 1.5);
      default:
        return const CallQualitySample(mos: 3.6);
    }
  }
}
