import 'package:firebase_messaging/firebase_messaging.dart';

import 'services/push_service.dart' show renderNexusAndroidNotification;
import 'voice/callkit_native.dart' show showNexusIncomingCall;

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
@pragma('vm:entry-point')
Future<void> nexusUnifiedBackgroundHandler(RemoteMessage message) async {
  // NOTE: separate isolate — NexusLog isn't configured here; use print().
  // ignore: avoid_print
  print('[NexusBG] handler fired — type=${message.data['type']} keys=${message.data.keys.toList()}');
  if (message.data['type'] == 'incoming_call') {
    await showNexusIncomingCall(message.data);
    return;
  }
  await renderNexusAndroidNotification(message);
}
