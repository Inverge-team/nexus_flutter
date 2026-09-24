import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';

import '../nexus_platform_interface.dart';
import 'services/push_service.dart' show renderNexusAndroidNotification;

/// Firebase allows only ONE `onBackgroundMessage` handler for the whole app —
/// the last registration wins. Voice (incoming calls) and Push (campaign
/// notifications) therefore MUST share a single dispatcher, or whichever
/// registers last silently drops the other. This is that single handler.

bool _registered = false;

/// Register the one shared FCM background handler. Idempotent — Voice and Push
/// both call it, but only the first registration takes effect. Runs in the main
/// isolate; the handler itself runs in a background isolate.
void ensureNexusBackgroundHandler() {
  if (_registered) return;
  _registered = true;
  FirebaseMessaging.onBackgroundMessage(nexusUnifiedBackgroundHandler);
}

/// The single background message handler. Dispatches incoming-call pushes to the
/// native ringer (Voice) and everything else to the notification renderer (Push).
/// Must be top-level + vm:entry-point to run in the background isolate.
///
/// The voice branches are ANDROID-only by construction: iOS rings from an APNs
/// VoIP (PushKit) push handled natively in `NexusVoiceManager.swift`, which never
/// reaches Firebase — a VoIP push must report a call to CallKit synchronously,
/// long before a Dart background isolate could spin up.
@pragma('vm:entry-point')
Future<void> nexusUnifiedBackgroundHandler(RemoteMessage message) async {
  if (message.data['type'] == 'incoming_call') {
    final d = message.data;
    final callId = (d['sessionId'] ?? d['session_id'] ?? '') as String? ?? '';
    if (Platform.isAndroid && callId.isNotEmpty) {
      // Ring in the SYSTEM call UI via our own native ConnectionService — the
      // call is answered natively, without opening the app (WhatsApp model).
      await NexusPlatform.instance.voiceReportIncoming(
        callId: callId,
        from: (d['from'] ?? d['callerNumber'] ?? '') as String? ?? '',
        displayName: d['callerName'] as String?,
      );
    }
    return;
  }
  // The caller hung up before we answered — dismiss the ring and leave a native
  // "Missed call" notification, even when the app is killed (realtime can't reach
  // a killed app, so the backend also pushes this cancel). iOS gets the same
  // cancel as a VoIP push, handled natively (report-then-end, as PushKit demands).
  if (message.data['type'] == 'cancel_call') {
    final d = message.data;
    final callId = (d['sessionId'] ?? d['session_id'] ?? '') as String? ?? '';
    if (Platform.isAndroid && callId.isNotEmpty) {
      await NexusPlatform.instance.voiceMissedCall(
        callId: callId,
        from: (d['from'] ?? d['callerNumber'] ?? '') as String? ?? '',
        displayName: d['callerName'] as String?,
      );
    }
    return;
  }
  await renderNexusAndroidNotification(message);
}
