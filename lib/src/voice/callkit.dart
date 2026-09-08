import 'dart:async';

/// Native calling seam — CallKit (iOS) / ConnectionService (Android) + VoIP push.
/// The SDK reports call lifecycle to the OS so incoming calls ring on the lock
/// screen and in-call actions come from the system UI. Provide a real
/// implementation (e.g. over `flutter_callkit_incoming`) via
/// `Nexus.instance.voice.useCallKit(...)`. The default is a no-op so the SDK runs
/// without the native dependency.
abstract class NexusCallKit {
  /// Show the system incoming-call UI. Returns when displayed.
  Future<void> reportIncoming({
    required String callId,
    required String handle,
    String? displayName,
    bool hasVideo = false,
  });

  /// Tell the OS the call connected (starts its timer / active-call UI).
  Future<void> reportConnected(String callId);

  /// Tell the OS the call ended (dismisses the call UI).
  Future<void> reportEnded(String callId);

  /// Actions the user takes from the system UI (answer / decline / mute / …).
  Stream<CallKitAction> get actions;

  /// The current VoIP push token (APNs PushKit / FCM), for the app to register
  /// with the backend so incoming calls can wake a killed app. Null if none.
  Future<String?> voipToken();
}

enum CallKitActionType { answer, decline, end, muted, hold, dtmf }

class CallKitAction {
  const CallKitAction(this.type, this.callId, {this.value});
  final CallKitActionType type;
  final String callId;
  final Object? value; // e.g. mute bool, dtmf digit
}

/// No-op default. The SDK still works for in-app (foreground) calling; the OS
/// call UI simply isn't shown until a real CallKit implementation is registered.
class NoopCallKit implements NexusCallKit {
  final _actions = StreamController<CallKitAction>.broadcast();
  @override
  Stream<CallKitAction> get actions => _actions.stream;
  @override
  Future<void> reportIncoming({required String callId, required String handle, String? displayName, bool hasVideo = false}) async {}
  @override
  Future<void> reportConnected(String callId) async {}
  @override
  Future<void> reportEnded(String callId) async {}
  @override
  Future<String?> voipToken() async => null;
}
