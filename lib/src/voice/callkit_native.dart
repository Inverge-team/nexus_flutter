import 'dart:async';

import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import '../logging.dart';
import 'callkit.dart';

/// The SDK's BUILT-IN native call UI, using flutter_callkit_incoming. Shows the
/// system incoming-call screen (CallKit on iOS, a full-screen call notification /
/// ConnectionService on Android) — including when the app is BACKGROUNDED or
/// KILLED — and reports lifecycle to the OS. Registered automatically when
/// `voiceEnabled`; developers never touch it. All calls are guarded.
class CallKitNativeHandler implements NexusCallKit {
  CallKitNativeHandler() {
    _sub = FlutterCallkitIncoming.onEvent.listen(_onEvent);
  }

  final _actions = StreamController<CallKitAction>.broadcast();
  StreamSubscription<CallEvent?>? _sub;

  @override
  Stream<CallKitAction> get actions => _actions.stream;

  @override
  Future<void> reportIncoming({
    required String callId,
    required String handle,
    String? displayName,
    bool hasVideo = false,
  }) async {
    try {
      await FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
        id: callId,
        nameCaller: displayName ?? handle,
        appName: 'Nexus',
        handle: handle,
        type: hasVideo ? 1 : 0,
        missedCallNotification: const NotificationParams(
          showNotification: true,
          isShowCallback: false,
        ),
        android: const AndroidParams(
          isCustomNotification: true,
          isShowLogo: false,
          ringtonePath: 'system_ringtone_default',
          backgroundColor: '#0955fa',
          actionColor: '#4CAF50',
        ),
        ios: const IOSParams(handleType: 'generic', supportsHolding: true, supportsDTMF: true),
      ));
    } catch (e) {
      NexusLog.warn('callkit: showIncoming ignored error: $e');
    }
  }

  @override
  Future<void> reportConnected(String callId) async {
    try {
      await FlutterCallkitIncoming.setCallConnected(callId);
    } catch (_) {/* ignore */}
  }

  @override
  Future<void> reportEnded(String callId) async {
    try {
      await FlutterCallkitIncoming.endCall(callId);
    } catch (_) {/* ignore */}
  }

  /// Start a native OUTGOING call entry (so the OS shows an active call + audio
  /// session is configured). Best-effort.
  @override
  Future<void> reportOutgoing({required String callId, required String handle, String? displayName}) async {
    try {
      await FlutterCallkitIncoming.startCall(CallKitParams(
        id: callId,
        nameCaller: displayName ?? handle,
        handle: handle,
        type: 0,
      ));
    } catch (_) {/* ignore */}
  }

  @override
  Future<String?> voipToken() async {
    try {
      // iOS PushKit VoIP token; on Android there is no VoIP token (FCM is used).
      return await FlutterCallkitIncoming.getDevicePushTokenVoIP();
    } catch (_) {
      return null;
    }
  }

  void _onEvent(CallEvent? event) {
    switch (event) {
      case CallEventActionCallAccept(:final callKitParams):
        _actions.add(CallKitAction(CallKitActionType.answer, callKitParams.id));
      case CallEventActionCallDecline(:final callKitParams):
        _actions.add(CallKitAction(CallKitActionType.decline, callKitParams.id));
      case CallEventActionCallEnded(:final callKitParams):
        _actions.add(CallKitAction(CallKitActionType.end, callKitParams.id));
      case CallEventActionCallTimeout(:final id):
        _actions.add(CallKitAction(CallKitActionType.end, id));
      case CallEventActionCallToggleMute(:final id, :final isMuted):
        _actions.add(CallKitAction(CallKitActionType.muted, id, value: isMuted));
      case CallEventActionCallToggleHold(:final id, :final isOnHold):
        _actions.add(CallKitAction(CallKitActionType.hold, id, value: isOnHold));
      case CallEventActionCallToggleDmtf(:final id, :final digits):
        _actions.add(CallKitAction(CallKitActionType.dtmf, id, value: digits));
      default:
        break;
    }
  }

  void dispose() {
    _sub?.cancel();
    _actions.close();
  }
}
