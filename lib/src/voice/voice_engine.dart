import 'dart:async';

import '../logging.dart';
import 'voice_models.dart';

/// The media-transport seam. Nexus Voice's control plane is engine-agnostic; the
/// actual WebRTC connection to the media plane (LiveKit) is provided by a
/// [NexusVoiceEngine]. Ship a real engine by registering one via
/// `Nexus.instance.voice.useEngine(...)` — e.g. a thin adapter over
/// `livekit_client` (see the SDK README). Keeping media out of the core keeps the
/// base package dependency-light and lets any transport slot in.
abstract class NexusVoiceEngine {
  /// Connect to the media plane for a leg and start capturing/playing audio.
  Future<void> connect(NexusJoinToken token);

  /// Tear down the media connection.
  Future<void> disconnect();

  Future<void> setMuted(bool muted);
  Future<void> setSpeakerphone(bool on);

  /// Send a DTMF digit over the media session (RFC 4733).
  Future<void> sendDtmf(String digit);

  /// Transport state changes (drive the call's connected/reconnecting state).
  Stream<VoiceEngineState> get states;

  /// Periodic quality samples (reported to the control plane + shown in-app).
  Stream<CallQualitySample> get quality;
}

enum VoiceEngineState { connecting, connected, reconnecting, disconnected, failed }

/// Default engine when none is registered: it does NO media. It logs and reports
/// a `connected` state so control-plane flows can be exercised end-to-end without
/// audio (useful in tests / before wiring a real transport). It never throws.
class NoopVoiceEngine implements NexusVoiceEngine {
  final _states = StreamController<VoiceEngineState>.broadcast();
  final _quality = StreamController<CallQualitySample>.broadcast();

  @override
  Stream<VoiceEngineState> get states => _states.stream;
  @override
  Stream<CallQualitySample> get quality => _quality.stream;

  @override
  Future<void> connect(NexusJoinToken token) async {
    NexusLog.warn('voice: no media engine registered — audio is inactive '
        '(register one via Nexus.instance.voice.useEngine). Room=${token.room}');
    _states.add(VoiceEngineState.connected);
  }

  @override
  Future<void> disconnect() async => _states.add(VoiceEngineState.disconnected);
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setSpeakerphone(bool on) async {}
  @override
  Future<void> sendDtmf(String digit) async {}
}
