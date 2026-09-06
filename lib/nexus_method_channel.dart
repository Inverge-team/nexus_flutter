import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'nexus_platform_interface.dart';

/// Method-channel implementation of [NexusPlatform] (Android/iOS/macOS/…).
class MethodChannelNexus extends NexusPlatform {
  MethodChannelNexus() {
    methodChannel.setMethodCallHandler(_handleNative);
  }

  @visibleForTesting
  final methodChannel = const MethodChannel('nexus');

  void Function(String recordingId, List<Object?> events)? _replaySink;
  void Function(Map<String, dynamic> data)? _tapSink;

  @override
  Future<String?> getPlatformVersion() =>
      methodChannel.invokeMethod<String>('getPlatformVersion');

  @override
  Future<Map<String, Object?>> deviceInfo() async {
    try {
      final res = await methodChannel.invokeMethod<Map<dynamic, dynamic>>(
        'deviceInfo',
      );
      return (res ?? {}).map((k, v) => MapEntry(k.toString(), v as Object?));
    } catch (_) {
      return <String, Object?>{};
    }
  }

  @override
  Future<void> startReplay(String recordingId) async {
    try {
      await methodChannel.invokeMethod('startReplay', {
        'recordingId': recordingId,
      });
    } catch (_) {
      /* native replay not available on this platform */
    }
  }

  @override
  Future<void> stopReplay() async {
    try {
      await methodChannel.invokeMethod('stopReplay');
    } catch (_) {}
  }

  @override
  void onReplayBatch(void Function(String, List<Object?>) sink) =>
      _replaySink = sink;

  @override
  Future<void> configureCrashReporting(bool enabled) async {
    try {
      await methodChannel.invokeMethod('configureCrashReporting', {
        'enabled': enabled,
      });
    } catch (_) {
      /* native crash reporting unavailable on this platform */
    }
  }

  @override
  Future<List<Map<String, Object?>>> takePendingCrashes() async {
    try {
      final res = await methodChannel.invokeMethod<List<dynamic>>(
        'takePendingCrashes',
      );
      return (res ?? const [])
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v as Object?)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<bool> showNotification({
    required int id,
    String? title,
    String? body,
    required String channelId,
    required String channelName,
    String? payload,
    String? largeIcon,
    String? bigPicture,
    String? smallIcon,
    String? visibility,
    String? accentColor,
    List<Map<String, String?>>? buttons,
  }) async {
    try {
      final ok = await methodChannel.invokeMethod<bool>('showNotification', {
        'id': id,
        'title': title,
        'body': body,
        'channelId': channelId,
        'channelName': channelName,
        'payload': payload,
        'largeIcon': largeIcon,
        'bigPicture': bigPicture,
        'smallIcon': smallIcon,
        'visibility': visibility,
        'accentColor': accentColor,
        'buttons': buttons,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  void onNotificationTap(void Function(Map<String, dynamic> data) sink) =>
      _tapSink = sink;

  @override
  Future<bool> showLiveActivity({
    required int id,
    required String channelId,
    required String channelName,
    String? title,
    String? body,
    String? subText,
    int? progress,
    bool indeterminate = false,
    bool ongoing = true,
    String? payload,
  }) async {
    try {
      final ok = await methodChannel.invokeMethod<bool>('showLiveActivity', {
        'id': id,
        'channelId': channelId,
        'channelName': channelName,
        'title': title,
        'body': body,
        'subText': subText,
        'progress': progress,
        'indeterminate': indeterminate,
        'ongoing': ongoing,
        'payload': payload,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> endLiveActivity(int id) async {
    try {
      await methodChannel.invokeMethod('endLiveActivity', {'id': id});
    } catch (_) {}
  }

  void Function(Map<String, dynamic> info)? _laTokenSink;

  @override
  Future<void> liveActivityStart({
    required String activityId,
    required String activityType,
    required Map<String, dynamic> contentState,
    Map<String, dynamic>? attributes,
  }) async {
    try {
      await methodChannel.invokeMethod('liveActivityStart', {
        'activityId': activityId,
        'activityType': activityType,
        'contentState': contentState,
        'attributes': attributes,
      });
    } catch (_) {}
  }

  @override
  Future<void> liveActivityUpdate({
    required String activityId,
    required Map<String, dynamic> contentState,
  }) async {
    try {
      await methodChannel.invokeMethod('liveActivityUpdate', {'activityId': activityId, 'contentState': contentState});
    } catch (_) {}
  }

  @override
  Future<void> liveActivityEnd({required String activityId, Map<String, dynamic>? finalContentState}) async {
    try {
      await methodChannel.invokeMethod('liveActivityEnd', {'activityId': activityId, 'contentState': finalContentState});
    } catch (_) {}
  }

  @override
  Future<void> liveActivityObservePushToStart(String activityType) async {
    try {
      await methodChannel.invokeMethod('liveActivityObservePushToStart', {'activityType': activityType});
    } catch (_) {}
  }

  @override
  void onLiveActivityToken(void Function(Map<String, dynamic> info) sink) => _laTokenSink = sink;

  Future<dynamic> _handleNative(MethodCall call) async {
    if (call.method == 'onReplayBatch') {
      final args = (call.arguments as Map);
      _replaySink?.call(
        args['recordingId'] as String,
        (args['events'] as List).cast<Object?>(),
      );
    } else if (call.method == 'onNotificationTap') {
      _tapSink?.call(_decode(call.arguments));
    } else if (call.method == 'onLiveActivityToken') {
      _laTokenSink?.call(_decode(call.arguments));
    }
    return null;
  }

  Map<String, dynamic> _decode(Object? raw) {
    try {
      if (raw is String) {
        final d = jsonDecode(raw);
        return d is Map ? d.cast<String, dynamic>() : const {};
      }
      if (raw is Map) return raw.cast<String, dynamic>();
    } catch (_) {}
    return const {};
  }
}
