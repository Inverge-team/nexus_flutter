import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../nexus_platform_interface.dart';

import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';

/// Live Activities — a live, updating view of an in-progress event on the iOS
/// Lock Screen / Dynamic Island and as an Android 16 Live Update (a promoted
/// ongoing notification; older Android: ongoing + progress bar).
///
/// Two ways to use it:
/// - **Server-driven** (recommended): design a template in the Nexus dashboard
///   (or send one via the API) and start/update/end it from your server. The SDK
///   renders it on both platforms — nothing to call here.
/// - **Local**: drive it from the app with [start] / [update] / [end].
///
/// iOS needs a one-time Widget Extension that hosts `NexusLiveActivityWidget`
/// (the `NexusLiveActivityKit` pod) — see the README. The SDK then manages the
/// ActivityKit lifecycle and registers push-to-start + update tokens for you.
/// For a custom `ActivityAttributes` type, manage ActivityKit yourself and call
/// [registerPushToStartToken] / [registerActivity].
class NexusLiveActivity {
  NexusLiveActivity(this._http, this._id);

  final NexusHttp _http;
  final NexusIdentity _id;

  /// The ActivityKit attributes type the SDK widget renders — the type
  /// server-driven starts target on iOS.
  static const iosActivityType = 'NexusLiveActivityAttributes';

  bool _wired = false;
  bool _prefetched = false;
  // Android local flow: the template of each locally started activity, so
  // [update] can re-render it.
  final Map<String, Map<String, dynamic>> _localTemplates = {};

  /// Wire native ActivityKit callbacks → backend registration and start
  /// observing (push-to-start tokens, push-started activities, diagnostics).
  /// Called at init when `liveActivityEnabled`.
  void wire() {
    if (_wired) return;
    _wired = true;
    NexusPlatform.instance.onLiveActivityToken(_onToken);
    if (_platform() == 'ios') unawaited(NexusPlatform.instance.liveActivityObservePushToStart(iosActivityType));
  }

  void _onToken(Map<String, dynamic> info) {
    if (info['kind'] == 'status') {
      _logStatus(info);
      return;
    }
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

  void _logStatus(Map<String, dynamic> info) {
    final event = info['event'];
    if (info['enabled'] == false) {
      NexusLog.warn('liveActivity: Live Activities are turned OFF for this app (iOS Settings → the app → '
          'Live Activities) — iOS silently drops every Live Activity push until it is turned back on');
    }
    if (event == 'start-failed') {
      NexusLog.warn('liveActivity: start failed for ${info['activityId']}: ${info['error']}');
    } else if (event == 'launch') {
      if ((info['appGroup'] ?? '') != '') unawaited(_prefetchAssets());
      final running = (info['running'] as List?) ?? const [];
      NexusLog.debug('liveActivity: enabled=${info['enabled']}, frequentPushes=${info['frequentPushes']}, '
          'running=${running.length}${running.isEmpty ? '' : ' $running'}'
          '${(info['appGroup'] ?? '') == '' ? ', no NexusAppGroup (remote images off)' : ', appGroup=${info['appGroup']}'}');
    } else {
      NexusLog.debug('liveActivity: $event ${info['activityId'] ?? ''} ${info['state'] ?? info['enabled'] ?? ''}'.trim());
    }
  }

  /// iOS: cache the environment's template images into the App Group, so a
  /// push-started activity can show them (widgets can't download). Once per
  /// launch — image URLs are immutable, so cached files never go stale.
  Future<void> _prefetchAssets() async {
    if (_prefetched) return;
    _prefetched = true;
    final res = await _http.post('/partner/live-activities/assets', const {});
    final urls = (res?['urls'] as List?)?.whereType<String>().toList() ?? const <String>[];
    if (urls.isEmpty) return;
    NexusLog.debug('liveActivity: caching ${urls.length} template image(s) for the widget');
    await cacheImages(urls);
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

  /// Start a live activity locally. iOS → ActivityKit (`NexusLiveActivityAttributes`);
  /// Android → a Live Update. With a [template] (the same JSON the dashboard
  /// produces) [contentState] is the template's data: `{ step, state, progress,
  /// etaAt, values }`. Also registers the instance so the server can update it.
  Future<void> start(
    String activityId,
    String activityType,
    Map<String, dynamic> contentState, {
    Map<String, dynamic>? attributes,
    Map<String, dynamic>? template,
  }) async {
    if (_platform() == 'ios') {
      await NexusPlatform.instance.liveActivityStart(
        activityId: activityId,
        activityType: activityType,
        contentState: contentState,
        attributes: attributes,
        template: template,
      );
    } else if (_platform() == 'android') {
      if (template != null) _localTemplates[activityId] = template;
      await renderNexusLiveActivity({
        'event': 'start',
        'activityId': activityId,
        'template': ?template,
        if (template != null) 'data': contentState else 'contentState': contentState,
      });
      await registerActivity(activityId: activityId, activityType: activityType, platform: 'android', contentState: contentState);
    }
  }

  Future<void> update(String activityId, Map<String, dynamic> contentState) async {
    if (_platform() == 'ios') {
      await NexusPlatform.instance.liveActivityUpdate(activityId: activityId, contentState: contentState);
    } else if (_platform() == 'android') {
      final template = _localTemplates[activityId];
      await renderNexusLiveActivity({
        'event': 'update',
        'activityId': activityId,
        'template': ?template,
        if (template != null) 'data': contentState else 'contentState': contentState,
      });
    }
  }

  Future<void> end(String activityId, {Map<String, dynamic>? finalContentState}) async {
    if (_platform() == 'ios') {
      await NexusPlatform.instance.liveActivityEnd(activityId: activityId, finalContentState: finalContentState);
    } else if (_platform() == 'android') {
      _localTemplates.remove(activityId);
      await NexusPlatform.instance.endLiveActivity(activityId.hashCode);
    }
  }

  /// iOS: pre-download template image URLs into the App Group, so a server
  /// push-started activity can show them (the widget itself can't download).
  /// Activities the SDK sees start are cached automatically.
  Future<void> cacheImages(List<String> urls) => NexusPlatform.instance.liveActivityCacheImages(urls);

  /// Kept for compatibility — observing now starts automatically in [wire].
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

/// Render (or end) an Android live notification from a server payload —
/// templated `{ event, activityId, template, data }` or plain `{ event,
/// activityId, contentState }`. Shared by the local API and the FCM
/// `nexus_live_activity` data-message handler (foreground + background).
Future<void> renderNexusLiveActivity(Map<String, dynamic> la) async {
  final event = la['event']?.toString();
  final activityId = la['activityId']?.toString() ?? '';
  if (activityId.isEmpty) return;
  final id = activityId.hashCode;
  if (event == 'end' && la['data'] == null) {
    await NexusPlatform.instance.endLiveActivity(id);
    return;
  }
  if (la['template'] is Map) {
    // Native renders the template (and an `end` with final data as a
    // dismissible final state).
    await NexusPlatform.instance.showLiveActivityTemplate(id: id, payload: la);
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
