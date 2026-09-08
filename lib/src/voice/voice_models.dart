// Client-side Voice models. Mirror the Nexus Voice control-plane concepts: a
// call is a session with legs; this device owns one WebRTC leg. State mirrors
// the server state machine so the UI can react without inventing its own flags.

/// Call state — the subset a client observes (mirrors the server machine).
enum VoiceCallState {
  idle,
  connecting, // placing / joining
  ringing, // outbound: remote ringing · inbound: incoming
  connected,
  onHold,
  reconnecting,
  ending,
  ended,
  failed,
  rejected,
  cancelled,
  timeout,
}

extension VoiceCallStateX on VoiceCallState {
  bool get isTerminal => const {
        VoiceCallState.ended,
        VoiceCallState.failed,
        VoiceCallState.rejected,
        VoiceCallState.cancelled,
        VoiceCallState.timeout,
      }.contains(this);
  bool get isActive => this == VoiceCallState.connected || this == VoiceCallState.onHold;
}

enum VoiceEndpointType { webrtc, sip, pstn, app }

enum VoiceCallDirection { inbound, outbound }

/// Everything a client needs to join the media plane for one leg. Minted by the
/// control plane; the client never fabricates any of it.
class NexusJoinToken {
  const NexusJoinToken({
    required this.room,
    required this.token,
    required this.url,
    this.turnUrls = const [],
    this.turnUsername,
    this.turnPassword,
  });

  final String room;
  final String token; // media access JWT
  final String url; // media wss endpoint
  final List<String> turnUrls;
  final String? turnUsername;
  final String? turnPassword;

  static NexusJoinToken? tryParse(Map<String, dynamic>? join) {
    if (join == null) return null;
    final access = join['access'] as Map<String, dynamic>?;
    if (access == null) return null;
    final turn = join['turn'] as Map<String, dynamic>?;
    return NexusJoinToken(
      room: (join['room'] ?? '') as String,
      token: (access['token'] ?? '') as String,
      url: (access['url'] ?? '') as String,
      turnUrls: ((turn?['urls'] as List?)?.cast<String>()) ?? const [],
      turnUsername: turn?['username'] as String?,
      turnPassword: turn?['password'] as String?,
    );
  }
}

/// One transport-quality sample the engine emits; reported to the control plane
/// and surfaced to the app for a live quality indicator.
class CallQualitySample {
  const CallQualitySample({
    this.rttMs,
    this.jitterMs,
    this.packetLoss,
    this.bitrateKbps,
    this.mos,
    this.codec,
    this.candidateType,
  });

  final int? rttMs;
  final int? jitterMs;
  final double? packetLoss; // 0..1
  final int? bitrateKbps;
  final double? mos; // 1..5 (engine-provided or server-estimated)
  final String? codec;
  final String? candidateType; // host | srflx | relay

  Map<String, Object?> toJson() => {
        if (rttMs != null) 'rttMs': rttMs,
        if (jitterMs != null) 'jitterMs': jitterMs,
        if (packetLoss != null) 'packetLoss': packetLoss,
        if (bitrateKbps != null) 'bitrateKbps': bitrateKbps,
        if (mos != null) 'mos': mos,
        if (codec != null) 'codec': codec,
        if (candidateType != null) 'candidateType': candidateType,
      };
}

/// Immutable snapshot of the current call, exposed via a [ValueListenable].
class NexusCall {
  const NexusCall({
    required this.sessionId,
    required this.direction,
    required this.state,
    this.legId,
    this.remoteAddress,
    this.remoteName,
    this.muted = false,
    this.onHold = false,
    this.speakerphone = false,
    this.startedAt,
    this.connectedAt,
    this.quality,
    this.endReason,
    this.metadata = const {},
  });

  final String sessionId;
  final String? legId; // this device's leg
  final VoiceCallDirection direction;
  final VoiceCallState state;
  final String? remoteAddress; // number/identity of the other party
  final String? remoteName;
  final bool muted;
  final bool onHold;
  final bool speakerphone;
  final DateTime? startedAt;
  final DateTime? connectedAt;
  final CallQualitySample? quality;
  final String? endReason;
  final Map<String, dynamic> metadata;

  NexusCall copyWith({
    String? legId,
    VoiceCallState? state,
    bool? muted,
    bool? onHold,
    bool? speakerphone,
    DateTime? connectedAt,
    CallQualitySample? quality,
    String? endReason,
  }) =>
      NexusCall(
        sessionId: sessionId,
        direction: direction,
        state: state ?? this.state,
        legId: legId ?? this.legId,
        remoteAddress: remoteAddress,
        remoteName: remoteName,
        muted: muted ?? this.muted,
        onHold: onHold ?? this.onHold,
        speakerphone: speakerphone ?? this.speakerphone,
        startedAt: startedAt,
        connectedAt: connectedAt ?? this.connectedAt,
        quality: quality ?? this.quality,
        endReason: endReason ?? this.endReason,
        metadata: metadata,
      );
}
