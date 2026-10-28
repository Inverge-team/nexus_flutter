import 'package:flutter/material.dart';

import '../nexus.dart';
import '../services/voice_service.dart';

/// State of an in-app IVR (visual phone-tree) session. The caller sees the
/// current [prompt]; when [awaitingInput] is true a keypad is shown and each
/// press calls [NexusVoice.pressIvrKey]. On reaching a "talk to an agent" step
/// the SDK connects a real call automatically ([status] → connecting), and the
/// [NexusIvrSession] clears once that call takes over.
enum NexusIvrStatus { active, connecting, ended }

@immutable
class NexusIvrSession {
  const NexusIvrSession({
    required this.sessionId,
    this.prompt,
    this.awaitingInput = false,
    this.maxDigits = 1,
    this.status = NexusIvrStatus.active,
    this.endedReason,
  });

  final String sessionId;
  final String? prompt;
  final bool awaitingInput;
  final int maxDigits;
  final NexusIvrStatus status;
  final String? endedReason; // 'ended' | 'no_agents' | 'voicemail_unavailable' | 'error'

  NexusIvrSession copyWith({
    String? prompt,
    bool? awaitingInput,
    int? maxDigits,
    NexusIvrStatus? status,
    String? endedReason,
  }) =>
      NexusIvrSession(
        sessionId: sessionId,
        prompt: prompt ?? this.prompt,
        awaitingInput: awaitingInput ?? this.awaitingInput,
        maxDigits: maxDigits ?? this.maxDigits,
        status: status ?? this.status,
        endedReason: endedReason ?? this.endedReason,
      );
}

/// The SDK's built-in IVR menu screen. Auto-shown whenever an IVR session is
/// active (alongside [NexusVoiceOverlay]); opt out with `autoShowOverlay: false`
/// and build your own from `Nexus.instance.voice.ivr`.
class NexusIvrOverlay extends StatelessWidget {
  const NexusIvrOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NexusIvrSession?>(
      valueListenable: Nexus.instance.voice.ivr,
      builder: (context, s, _) {
        if (s == null) return const SizedBox.shrink();
        return _IvrScreen(session: s);
      },
    );
  }
}

class _IvrScreen extends StatelessWidget {
  const _IvrScreen({required this.session});
  final NexusIvrSession session;

  static const _keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];

  @override
  Widget build(BuildContext context) {
    final v = Nexus.instance.voice;
    final ended = session.status == NexusIvrStatus.ended;
    final connecting = session.status == NexusIvrStatus.connecting;

    return Material(
      color: const Color(0xFF0B1622),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 12),
              const Icon(Icons.support_agent, color: Colors.white70, size: 40),
              const SizedBox(height: 20),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Text(
                      connecting
                          ? 'Connecting you to an agent…'
                          : session.prompt ?? (ended ? 'Thanks for calling.' : '…'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 20, height: 1.4),
                    ),
                  ),
                ),
              ),
              if (session.awaitingInput && !ended && !connecting) _keypad(v),
              if (connecting) const Padding(
                padding: EdgeInsets.only(bottom: 24),
                child: CircularProgressIndicator(color: Colors.white54),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => v.endIvr(),
                child: Text(ended ? 'Close' : 'Cancel', style: const TextStyle(color: Colors.white70, fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _keypad(NexusVoice v) {
    return GridView.count(
      shrinkWrap: true,
      crossAxisCount: 3,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.6,
      physics: const NeverScrollableScrollPhysics(),
      children: _keys
          .map((k) => InkResponse(
                onTap: () => v.pressIvrKey(k),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white24),
                  ),
                  alignment: Alignment.center,
                  child: Text(k, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600)),
                ),
              ))
          .toList(),
    );
  }
}
