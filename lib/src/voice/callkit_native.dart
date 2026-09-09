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
      // Android 14+ CallStyle REQUIRES a non-empty caller name (it builds a
      // Person from it) — an empty name throws and the call UI never shows.
      final name = (displayName != null && displayName.isNotEmpty)
          ? displayName
          : (handle.isNotEmpty ? handle : 'Incoming call');
      await FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
        id: callId,
        nameCaller: name,
        appName: 'Nexus',
        handle: handle.isNotEmpty ? handle : name,
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
          // Show the full-screen incoming UI over the lock screen and treat it as
          // a high-importance call (heads-up + screen wake), like WhatsApp.
          isShowFullLockedScreen: true,
          isImportant: true,
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

  /// The session id of a call the user has already ACCEPTED from the system UI
  /// (e.g. accepting from a killed app, before Dart wired up). Null if none.
  Future<String?> acceptedCallId() async {
    try {
      final dynamic calls = await FlutterCallkitIncoming.activeCalls();
      if (calls is List) {
        for (final dynamic c in calls) {
          try {
            if (c['isAccepted'] == true) return c['id'] as String?;
          } catch (_) {/* not a map-like entry */}
        }
      }
    } catch (_) {/* ignore */}
    return null;
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

/// Show the native incoming-call UI directly from a voice push payload. Safe to
/// call from a background isolate (e.g. an FCM background handler) when the app
/// is backgrounded or killed — it uses only the native plugin, not Nexus state.
/// Register your FCM background handler and forward voice pushes to this:
/// ```dart
/// @pragma('vm:entry-point')
/// Future<void> _bg(RemoteMessage m) async {
///   if (m.data['type'] == 'incoming_call') await showNexusIncomingCall(m.data);
/// }
/// FirebaseMessaging.onBackgroundMessage(_bg);
/// ```
Future<void> showNexusIncomingCall(Map<dynamic, dynamic> data) async {
  final id = (data['sessionId'] ?? data['session_id'] ?? '') as String? ?? '';
  if (id.isEmpty) return;
  final from = (data['from'] ?? data['callerNumber'] ?? '') as String? ?? '';
  final name = data['callerName'] as String?;
  // Android 14+ CallStyle requires a non-empty caller name or it throws.
  final display = (name != null && name.isNotEmpty) ? name : (from.isNotEmpty ? from : 'Incoming call');
  try {
    await FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
      id: id,
      nameCaller: display,
      appName: 'Nexus',
      handle: from.isNotEmpty ? from : display,
      type: 0,
      extra: {'from': from, 'callerName': ?name},
      android: const AndroidParams(
        isCustomNotification: true,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0955fa',
        actionColor: '#4CAF50',
        // Full-screen incoming call over the lock screen, screen wake — WhatsApp-style.
        isShowFullLockedScreen: true,
        isImportant: true,
      ),
      ios: const IOSParams(handleType: 'generic', supportsHolding: true),
    ));
  } catch (_) {/* ignore */}
}
