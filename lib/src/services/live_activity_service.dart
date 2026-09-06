import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../nexus_platform_interface.dart';

import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';

/// Live Activities — a live, updating view of an in-progress event on the iOS
/// Lock Screen / Dynamic Island and as an Android live ongoing notification.
///
/// Two ways to use it:
/// - **Server-driven** (recommended): start/update/end from the dashboard or the
///   Live Activity API. iOS receives ActivityKit push updates; Android receives a
///   data message the SDK turns into a live notification — nothing to call here.
/// - **Local**: drive it from the app with [start] / [update] / [end].
///
/// For iOS you also ship a Widget Extension (the ActivityKit layout). With the
/// turn-key default attributes the SDK manages the ActivityKit lifecycle and
/// registers push-to-start + update tokens for you; for a typed setup, manage
/// ActivityKit yourself and call [registerPushToStartToken] / [registerActivity].
class NexusLiveActivity {
  NexusLiveActivity(this._http, this._id);

  final NexusHttp _http;
  final NexusIdentity _id;

  bool _wired = false;

  /// Wire native ActivityKit token callbacks → backend registration. Called at
  /// init when `liveActivityEnabled`.
  void wire() {
    if (_wired) return;
    _wired = true;
    NexusPlatform.instance.onLiveActivityToken(_onToken);
  }

  void _onToken(Map<String, dynamic> info) {
    final token = info['token']?.toString();
    if (token == null) return;
    if (info['kind'] == 'pushToStart') {
      unawaited(registerPushToStartToken(info['activityType']?.toString() ?? '', token));
    } else if (info['kind'] == 'update') {
      unawaited(registerActivity(
        activityId: info['activityId']?.toString() ?? '',
        activityType: info['activityType']?.toString() ?? '',
        platform: 'ios',
        updateToken: token,
      ));
    }
  }

  // ---- backend registration ----

  Future<void> registerPushToStartToken(String activityType, String token) async {
    if (activityType.isEmpty || token.isEmpty) return;
    NexusLog.debug('liveActivity.pushToStart — $activityType');
    await _http.post('/partner/live-activities/push-token', {
      'activityType': activityType,
      'token': token,
      'distinctId': ?_id.distinctId,
      'deviceKey': _id.deviceKey,
    });
  }

  Future<void> registerActivity({
    required String activityId,
    required String activityType,
    required String platform,
    String? updateToken,
    Map<String, dynamic>? contentState,
  }) async {
    await _http.post('/partner/live-activities/register', {
      'activityId': activityId,
      'activityType': activityType,
      'platform': platform,
      'updateToken': ?updateToken,
      'distinctId': ?_id.distinctId,
      'contentState': ?contentState,
    });
  }

  /// Report a receipt / click / failure for analytics.
  Future<void> reportEvent(String activityId, String type) async {
    await _http.post('/partner/live-activities/event', {'activityId': activityId, 'type': type});
  }

  // ---- local start / update / end ----

  /// Start a live activity locally. iOS → ActivityKit (default attributes);
  /// Android → a live ongoing notification. Also registers the instance so the
  /// server can update it.
  Future<void> start(
    String activityId,
    String activityType,
    Map<String, dynamic> contentState, {
    Map<String, dynamic>? attributes,
  }) async {
    if (_platform() == 'ios') {
      await NexusPlatform.instance.liveActivityStart(
        activityId: activityId,
        activityType: activityType,
        contentState: contentState,
        attributes: attributes,
      );
    } else if (_platform() == 'android') {
      await renderNexusLiveActivity({'event': 'start', 'activityId': activityId, 'contentState': contentState});
      await registerActivity(activityId: activityId, activityType: activityType, platform: 'android', contentState: contentState);
    }
  }

  Future<void> update(String activityId, Map<String, dynamic> contentState) async {
    if (_platform() == 'ios') {
      await NexusPlatform.instance.liveActivityUpdate(activityId: activityId, contentState: contentState);
    } else if (_platform() == 'android') {
      await renderNexusLiveActivity({'event': 'update', 'activityId': activityId, 'contentState': contentState});
    }
  }

  Future<void> end(String activityId, {Map<String, dynamic>? finalContentState}) async {
    if (_platform() == 'ios') {
      await NexusPlatform.instance.liveActivityEnd(activityId: activityId, finalContentState: finalContentState);
    } else if (_platform() == 'android') {
      await NexusPlatform.instance.endLiveActivity(activityId.hashCode);
    }
  }

  /// Observe push-to-start tokens (iOS 17.2+) so the server can start activities
  /// remotely. No-op off iOS.
  Future<void> observePushToStart(String activityType) =>
      NexusPlatform.instance.liveActivityObservePushToStart(activityType);

  String? _platform() {
    if (kIsWeb) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      default:
        return null;
    }
  }
}

/// Render (or end) an Android live ongoing notification from a server payload
/// `{ event, activityId, contentState }`. Shared by the local API and the FCM
/// `nexus_live_activity` data-message handler (foreground + background).
Future<void> renderNexusLiveActivity(Map<String, dynamic> la) async {
  final event = la['event']?.toString();
  final activityId = la['activityId']?.toString() ?? '';
  if (activityId.isEmpty) return;
  final id = activityId.hashCode;
  if (event == 'end') {
    await NexusPlatform.instance.endLiveActivity(id);
    return;
  }
  final cs = (la['contentState'] as Map?)?.cast<String, dynamic>() ?? const {};
  await NexusPlatform.instance.showLiveActivity(
    id: id,
    channelId: 'nexus_live',
    channelName: 'Live activities',
    title: cs['title']?.toString(),
    body: (cs['body'] ?? cs['status'])?.toString(),
    subText: (cs['subtitle'] ?? cs['subText'])?.toString(),
    progress: (cs['progress'] as num?)?.toInt(),
    indeterminate: cs['indeterminate'] == true,
    ongoing: true,
    payload: jsonEncode(la),
  );
}

/// Parse the `nexus_live_activity` data value (JSON string or map) into a map.
Map<String, dynamic>? parseLiveActivityPayload(Object? raw) {
  if (raw is String && raw.isNotEmpty) {
    try {
      final d = jsonDecode(raw);
      if (d is Map) return d.cast<String, dynamic>();
    } catch (_) {}
  }
  if (raw is Map) return raw.cast<String, dynamic>();
  return null;
}
