import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../nexus_platform_interface.dart';
import '../logging.dart';
import 'callkit.dart';

/// The SDK's BUILT-IN native call UI, over the SDK's OWN native layer — no
/// third-party call package on either platform.
///
/// * **iOS** → `NexusVoiceManager.swift`: CallKit (the system incoming-call
///   screen, over the lock screen, working backgrounded AND killed) + PushKit
///   for the VoIP wake-up.
/// * **Android** → `NexusVoiceManager.kt`: a self-managed Telecom
///   ConnectionService with its own lock-screen call UI.
///
/// Android drives that stack directly from [NexusVoice] (the proven path), so
/// this handler is a deliberate **no-op there** and only carries iOS. Registered
/// automatically when `voiceEnabled`; developers never touch it. All calls are
/// guarded — the call UI never throws into the app.
class NexusNativeCallKit implements NexusCallKit {
  NexusNativeCallKit() {
    if (!_active) return;
    // In-call controls the user drove from the SYSTEM call UI (mute / hold /
    // DTMF keypad). Answer / decline / hangup arrive on the shared
    // `onNativeCallEvent` channel instead — the same one Android uses.
    NexusPlatform.instance.onNativeCallControl((action, callId, value) {
      switch (action) {
        case 'mute':
          _actions.add(CallKitAction(CallKitActionType.muted, callId, value: value == true));
        case 'hold':
          _actions.add(CallKitAction(CallKitActionType.hold, callId, value: value == true));
        case 'dtmf':
          if (value is String && value.isNotEmpty) {
            _actions.add(CallKitAction(CallKitActionType.dtmf, callId, value: value));
          }
      }
    });
  }

  /// Only iOS routes through this seam (see the class doc).
  static bool get _active => !kIsWeb && Platform.isIOS;

  final _actions = StreamController<CallKitAction>.broadcast();

  @override
  Stream<CallKitAction> get actions => _actions.stream;

  @override
  Future<void> reportIncoming({
    required String callId,
    required String handle,
    String? displayName,
    bool hasVideo = false,
  }) async {
    if (!_active) return;
    await NexusPlatform.instance.voiceReportIncoming(
      callId: callId,
      from: handle,
      displayName: displayName,
      hasVideo: hasVideo,
    );
  }

  @override
  Future<void> reportOutgoing({required String callId, required String handle, String? displayName}) async {
    if (!_active) return;
    await NexusPlatform.instance.voiceReportOutgoing(
      callId: callId,
      to: handle,
      displayName: displayName,
    );
  }

  @override
  Future<void> reportConnected(String callId) async {
    if (!_active) return;
    await NexusPlatform.instance.voiceReportConnected(callId);
  }

  @override
  Future<void> reportEnded(String callId) async {
    if (!_active) return;
    await NexusPlatform.instance.voiceEndCall(callId);
  }

  /// The caller gave up before we answered → end the ring as MISSED and leave a
  /// "Missed call" trace (system Recents + a notification), like Android does.
  Future<void> reportMissed({required String callId, required String from, String? displayName}) async {
    if (!_active) return;
    await NexusPlatform.instance.voiceMissedCall(callId: callId, from: from, displayName: displayName);
  }

  @override
  Future<String?> voipToken() async {
    if (!_active) return null;
    final t = await NexusPlatform.instance.voiceVoipToken();
    return (t == null || t.isEmpty) ? null : t;
  }

  void dispose() {
    _actions.close();
  }
}

/// Show the native incoming-call UI directly from a voice push payload.
///
/// Only needed on **Android**, where the incoming-call push is an FCM data
/// message the SDK handles in a background Dart isolate. On iOS the ring is
/// raised natively from the APNs VoIP (PushKit) payload before Dart is involved
/// at all, so nothing here runs on that path.
///
/// The SDK wires its own FCM background handler, so apps do not normally call
/// this; it stays public for apps that own their FCM handler end to end.
Future<void> showNexusIncomingCall(Map<dynamic, dynamic> data) async {
  final id = (data['sessionId'] ?? data['session_id'] ?? '') as String? ?? '';
  if (id.isEmpty) return;
  final from = (data['from'] ?? data['callerNumber'] ?? '') as String? ?? '';
  final name = data['callerName'] as String?;
  try {
    await NexusPlatform.instance.voiceReportIncoming(callId: id, from: from, displayName: name);
  } catch (e) {
    // Background isolate — NexusLog isn't configured here; keep a minimal
    // failure breadcrumb (visible in logcat as I/flutter) for field debugging.
    // ignore: avoid_print
    print('[NexusVoice] voiceReportIncoming failed: $e');
    NexusLog.warn('voice: native incoming ring failed: $e');
  }
}
