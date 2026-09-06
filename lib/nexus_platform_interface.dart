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

  /// Post a notification from native code (used to render foreground pushes on
  /// Android, since FCM does not draw one while the app is open). Returns `true`
  /// if it was shown. No-op / `false` where unsupported. [payload] is stashed on
  /// the tap intent and delivered back via [onNotificationTap].
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
  }) async => false;

  /// Register a sink for taps on notifications posted via [showNotification].
  /// Receives the decoded [payload] map so the caller can attribute the open.
  void onNotificationTap(void Function(Map<String, dynamic> data) sink) {}

  /// Post or update an Android live ongoing notification (the Android equivalent
  /// of an iOS Live Activity). Uses a promoted Live Update (ProgressStyle) on
  /// Android 16+, a normal ongoing notification with a progress bar otherwise.
  /// Returns `true` if shown.
  Future<bool> showLiveActivity({
    required int id,
    required String channelId,
    required String channelName,
    String? title,
    String? body,
    String? subText,
    int? progress, // 0..100, null = no bar
    bool indeterminate = false,
    bool ongoing = true,
    String? payload,
  }) async => false;

  /// Remove an Android live ongoing notification (end of a live activity).
  Future<void> endLiveActivity(int id) async {}

  // ---- iOS ActivityKit bridge (no-ops on other platforms) ----

  /// Start an iOS Live Activity (ActivityKit) with the turn-key default
  /// attributes. The native side registers its update token via [onLiveActivityToken].
  Future<void> liveActivityStart({
    required String activityId,
    required String activityType,
    required Map<String, dynamic> contentState,
    Map<String, dynamic>? attributes,
  }) async {}

  /// Update a running iOS Live Activity's content state.
  Future<void> liveActivityUpdate({
    required String activityId,
    required Map<String, dynamic> contentState,
  }) async {}

  /// End a running iOS Live Activity.
  Future<void> liveActivityEnd({required String activityId, Map<String, dynamic>? finalContentState}) async {}

  /// Observe push-to-start tokens (iOS 17.2+) for an activity type; tokens are
  /// delivered via [onLiveActivityToken].
  Future<void> liveActivityObservePushToStart(String activityType) async {}

  /// Register a sink for ActivityKit tokens. `info` carries
  /// `{ kind: 'pushToStart'|'update', activityType?, activityId?, token }`.
  void onLiveActivityToken(void Function(Map<String, dynamic> info) sink) {}
}
