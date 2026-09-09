import 'dart:async';

import 'package:flutter/material.dart';

import '../nexus.dart';
import '../services/voice_service.dart';
import 'voice_models.dart';

/// The SDK's built-in, auto-shown call screen. Renders full-screen whenever
/// there is an active call (`Nexus.instance.voice.current`) — outbound and
/// incoming — with mute / speaker / hold / hangup (and accept / decline while
/// ringing inbound). Auto-mounted when `voiceEnabled`; opt out with
/// `NexusConfig(autoShowOverlay: false)` and place your own UI, or wrap
/// [NexusVoiceOverlay] yourself.
class NexusVoiceOverlay extends StatefulWidget {
  const NexusVoiceOverlay({super.key, this.child});
  final Widget? child;

  @override
  State<NexusVoiceOverlay> createState() => _NexusVoiceOverlayState();
}

class _NexusVoiceOverlayState extends State<NexusVoiceOverlay> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Repaint once a second so the in-call timer advances.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (widget.child != null) widget.child!,
        ValueListenableBuilder<NexusCall?>(
          valueListenable: Nexus.instance.voice.current,
          builder: (context, call, _) {
            // While an INBOUND call is still ringing, the native full-screen
            // CallKit ringer owns the screen (incl. over the lock screen) — don't
            // also draw our in-app screen, or the user sees two call UIs. Our
            // screen takes over once the call is answered (connecting/connected).
            final inboundRinging = call != null &&
                call.direction == VoiceCallDirection.inbound &&
                call.state == VoiceCallState.ringing;
            if (call == null ||
                (call.state == VoiceCallState.ended && call.connectedAt == null) ||
                inboundRinging) {
              return const SizedBox.shrink();
            }
            return _CallScreen(call: call);
          },
        ),
      ],
    );
  }
}

class _CallScreen extends StatelessWidget {
  const _CallScreen({required this.call});
  final NexusCall call;

  String get _title => call.remoteName ?? call.remoteAddress ?? 'Call';

  String get _status {
    switch (call.state) {
      case VoiceCallState.connecting:
        return 'Connecting…';
      case VoiceCallState.ringing:
        return call.direction == VoiceCallDirection.inbound ? 'Incoming call' : 'Ringing…';
      case VoiceCallState.connected:
        return _duration();
      case VoiceCallState.onHold:
        return 'On hold';
      case VoiceCallState.reconnecting:
        return 'Reconnecting…';
      case VoiceCallState.ended:
      case VoiceCallState.failed:
      case VoiceCallState.rejected:
      case VoiceCallState.cancelled:
      case VoiceCallState.timeout:
        return 'Call ended';
      default:
        return '';
    }
  }

  String _duration() {
    final start = call.connectedAt;
    if (start == null) return 'Connected';
    final s = DateTime.now().difference(start).inSeconds;
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final v = Nexus.instance.voice;
    final ringingInbound = call.state == VoiceCallState.ringing && call.direction == VoiceCallDirection.inbound;
    final active = call.state.isActive;

    return Material(
      color: const Color(0xFF0B1622),
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            CircleAvatar(
              radius: 52,
              backgroundColor: const Color(0xFF1E3550),
              child: Text(
                _title.isNotEmpty ? _title.characters.first.toUpperCase() : '?',
                style: const TextStyle(fontSize: 40, color: Colors.white),
              ),
            ),
            const SizedBox(height: 20),
            Text(_title, style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(_status, style: const TextStyle(fontSize: 15, color: Colors.white70)),
            if (call.quality?.mos != null && active) ...[
              const SizedBox(height: 6),
              Text('Audio ${_quality(call.quality!.mos!)}', style: const TextStyle(fontSize: 12, color: Colors.white38)),
            ],
            const Spacer(),
            if (active) _controls(v),
            const SizedBox(height: 28),
            ringingInbound ? _answerRow(v) : _hangupButton(v),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  String _quality(double mos) =>
      mos >= 4.2 ? 'excellent' : mos >= 4.0 ? 'good' : mos >= 3.6 ? 'fair' : mos >= 3.1 ? 'poor' : 'bad';

  Widget _controls(NexusVoice v) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _round(icon: call.muted ? Icons.mic_off : Icons.mic, label: 'Mute', on: call.muted, onTap: () => v.setMuted(!call.muted)),
        const SizedBox(width: 28),
        _round(icon: Icons.volume_up, label: 'Speaker', on: call.speakerphone, onTap: () => v.setSpeakerphone(!call.speakerphone)),
        const SizedBox(width: 28),
        _round(icon: Icons.pause, label: 'Hold', on: call.onHold, onTap: () => v.setHold(!call.onHold)),
      ],
    );
  }

  Widget _round({required IconData icon, required String label, required bool on, required VoidCallback onTap}) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      InkResponse(
        onTap: onTap,
        child: Container(
          width: 62,
          height: 62,
          decoration: BoxDecoration(color: on ? Colors.white : Colors.white24, shape: BoxShape.circle),
          child: Icon(icon, color: on ? const Color(0xFF0B1622) : Colors.white, size: 26),
        ),
      ),
      const SizedBox(height: 8),
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
    ]);
  }

  Widget _hangupButton(NexusVoice v) {
    return _bigButton(color: const Color(0xFFE53935), icon: Icons.call_end, onTap: () => v.hangup());
  }

  Widget _answerRow(NexusVoice v) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _bigButton(color: const Color(0xFFE53935), icon: Icons.call_end, onTap: () => v.decline()),
        _bigButton(color: const Color(0xFF43A047), icon: Icons.call, onTap: () => v.answer()),
      ],
    );
  }

  Widget _bigButton({required Color color, required IconData icon, required VoidCallback onTap}) {
    return InkResponse(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 32),
      ),
    );
  }
}
