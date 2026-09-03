import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'nexus_method_channel.dart';

/// The native surface of the SDK: device/app context and (native-backed) session
/// replay capture. Platform implementations (Kotlin/Swift/web) provide these; the
/// pure-Dart services (events, errors, logs, realtime, …) work without native code.
abstract class NexusPlatform extends PlatformInterface {
  NexusPlatform() : super(token: _token);

  static final Object _token = Object();
  static NexusPlatform _instance = MethodChannelNexus();

  static NexusPlatform get instance => _instance;
  static set instance(NexusPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }

  /// Device + OS + app context (osType, osVersion, deviceModel, appVersion, …).
  Future<Map<String, Object?>> deviceInfo() async => <String, Object?>{};

  /// Begin native session-replay capture for [recordingId]. No-op where the
  /// native SDK isn't present (web/desktop today).
  Future<void> startReplay(String recordingId) async {}

  /// Stop native session-replay capture.
  Future<void> stopReplay() async {}

  /// Register a sink for batches of replay events pushed up from native.
  void onReplayBatch(
    void Function(String recordingId, List<Object?> events) sink,
  ) {}

  /// Install (or remove) the native uncaught-exception / signal handlers that
  /// persist crashes for forwarding on the next launch. No-op where unsupported.
  Future<void> configureCrashReporting(bool enabled) async {}

  /// Return and clear native crashes persisted since the last launch. Each map:
  /// `{ type, message, stack (frames or string), platform, timestamp }`.
  Future<List<Map<String, Object?>>> takePendingCrashes() async => const [];
}
