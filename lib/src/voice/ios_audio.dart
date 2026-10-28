// LiveKit marks its CallKit coordination API (`externalCallSystem` +
// `setEngineAvailability`) `@experimental`. It is nonetheless the ONLY supported
// way to hand the audio session to CallKit, and is what LiveKit's own CallKit
// guidance prescribes — so the warning is acknowledged here rather than at every
// call site. Re-check on each `livekit_client` major bump.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:livekit_client/livekit_client.dart' as lk;

import '../logging.dart';

/// iOS call-audio coordination with CallKit.
///
/// On iOS the **external call system owns the AVAudioSession**: CallKit decides
/// when the session becomes active (`provider(_:didActivate:)`) and when it is
/// torn down. If LiveKit also activated the session, the two would fight and the
/// call would come up silent — the classic CallKit/WebRTC bug.
///
/// So the SDK puts LiveKit in [lk.AudioSessionManagementMode.externalCallSystem]
/// (it still configures category/mode, but never activates) and gates the WebRTC
/// audio engine on CallKit's activate/deactivate window. Requests made while the
/// engine is gated off are not lost — LiveKit starts them as soon as it opens,
/// so a room may be connected and the mic published before CallKit activates.
///
/// **The gate can only be set once a media session exists.** The WebRTC audio
/// device module is created with the first `Room`, and until then the native side
/// rejects the call with "audio device module is unavailable". The desired state
/// is therefore remembered and (re)applied from [applyPending], which the media
/// engine calls once it has connected.
///
/// Android is untouched: it has no audio session to arbitrate and LiveKit keeps
/// its normal management there. Every method is a no-op off iOS.
class NexusCallAudio {
  NexusCallAudio._();

  /// How long the audio engine may stay shut after media is up before we assume
  /// CallKit's `didActivate` is never coming and open it anyway. A call that is
  /// silent forever is a far worse failure than one whose audio starts a moment
  /// early, so this never lets the gate strand a live call.
  static const Duration _activationGrace = Duration(seconds: 5);

  static bool _prepared = false;
  static bool _desiredActive = false;
  static bool _micGranted = true;
  static Timer? _watchdog;

  static bool get _isIos => !kIsWeb && Platform.isIOS;

  /// Whether the media engine may open the microphone at all. Always true off
  /// iOS, where LiveKit's own error handling applies.
  ///
  /// On iOS this is a HARD safety gate, not a preference: opening the mic
  /// without authorization — or with no `NSMicrophoneUsageDescription` in the
  /// host app's Info.plist — does not fail gracefully, it terminates the process
  /// through TCC. The call still runs; it is simply receive-only until access
  /// exists.
  static bool get microphoneAvailable => !_isIos || _micGranted;

  /// Record whether microphone access is held, and re-gate the audio engine to
  /// match. Called by the voice service after every permission check.
  static Future<void> setMicrophoneGranted(bool granted) async {
    if (!_isIos || _micGranted == granted) return;
    _micGranted = granted;
    await _apply();
  }

  /// Hand the audio session to CallKit. Idempotent; called when voice initialises.
  static Future<void> prepare() async {
    if (!_isIos || _prepared) return;
    _prepared = true;
    try {
      await lk.AudioManager.instance
          .setAudioSessionManagementMode(lk.AudioSessionManagementMode.externalCallSystem);
      NexusLog.debug('voice: iOS audio session handed to CallKit');
    } catch (e) {
      NexusLog.warn('voice: CallKit audio mode could not be set: $e');
    }
    // Start gated off, best-effort: before the first Room there is no audio
    // device module to gate, which is expected and not an error.
    await _apply();
  }

  /// CallKit activated (or deactivated) the shared audio session — open or close
  /// the WebRTC audio engine to match.
  static Future<void> setActive(bool active) async {
    if (!_isIos) return;
    _desiredActive = active;
    if (active) {
      _watchdog?.cancel();
      _watchdog = null;
    }
    await _apply();
  }

  /// Re-apply the gate now that a media session (and therefore the audio device
  /// module) exists. Called by the engine right after it connects.
  static Future<void> applyPending() async {
    if (!_isIos) return;
    await _apply();
    if (!_desiredActive) _armWatchdog();
  }

  /// Media is up but CallKit has not opened the audio window. Give it a moment,
  /// then open the engine ourselves rather than leave the call mute.
  static void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(_activationGrace, () async {
      if (_desiredActive) return;
      NexusLog.warn('voice: CallKit never activated the audio session — opening the '
          'audio engine anyway so the call is not silent');
      _desiredActive = true;
      await _apply();
    });
  }

  static Future<void> _apply() async {
    if (!_isIos) return;
    try {
      // Input and output are gated SEPARATELY. Without microphone access the
      // output side still runs — so the user hears the other party — while the
      // input side stays shut, which is what keeps iOS from killing the app.
      await lk.AudioManager.instance.setEngineAvailability(
        lk.AudioEngineAvailability(
          isInputAvailable: _desiredActive && _micGranted,
          isOutputAvailable: _desiredActive,
        ),
      );
      NexusLog.debug('voice: CallKit audio window ${_desiredActive ? 'open' : 'closed'}'
          '${_desiredActive && !_micGranted ? ' (receive-only — no microphone access)' : ''}');
    } catch (e) {
      // Before the first Room (and after the last one is disposed) there is no
      // audio device module. Expected — the state is re-applied from
      // [applyPending] once media exists.
      NexusLog.debug('voice: audio gate deferred (no media session yet): $e');
    }
  }

  /// Drop the watchdog so it can never reopen the gate for a session that no
  /// longer exists.
  ///
  /// Deliberately does NOT clear the desired state: CallKit owns that, and
  /// `connect()` tears the previous session down *after* `didActivate` has
  /// already fired for the new call. Clearing it here would re-close a window
  /// CallKit had just opened and leave the first seconds of every answered call
  /// silent until the watchdog fired.
  static void reset() {
    _watchdog?.cancel();
    _watchdog = null;
  }
}
