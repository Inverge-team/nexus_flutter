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

  Future<dynamic> _handleNative(MethodCall call) async {
    if (call.method == 'onReplayBatch') {
      final args = (call.arguments as Map);
      _replaySink?.call(
        args['recordingId'] as String,
        (args['events'] as List).cast<Object?>(),
      );
    }
    return null;
  }
}
