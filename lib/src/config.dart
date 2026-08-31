/// Configuration for [Nexus.init].
class NexusConfig {
  const NexusConfig({
    required this.apiKey,
    this.baseUrl = 'https://api.nexus.inverge.net',
    this.realtimeUrl,
    this.autoTrackSessions = true,
    this.autoCaptureErrors = true,
    this.flushInterval = const Duration(seconds: 10),
    this.maxBatch = 50,
    this.logging = false,
    this.appVersion,
    this.defaultProperties = const {},
  });

  /// Tenant API key (`nxs_...`). Sent as `x-api-key` on HTTP and in the socket
  /// handshake auth.
  final String apiKey;

  /// Control-plane / data-plane origin. Partner endpoints live under `/partner`.
  final String baseUrl;

  /// Realtime (Socket.IO) origin. Defaults to [baseUrl] when null.
  final String? realtimeUrl;

  /// Start (and keep alive) a journey session automatically. Default `true`.
  final bool autoTrackSessions;

  /// Install a Flutter error handler that reports uncaught errors. Default `true`.
  final bool autoCaptureErrors;

  /// How often batched telemetry (events/logs) is flushed. Default 10s.
  final Duration flushInterval;

  /// Max items per batch flush. Default 50.
  final int maxBatch;

  /// Verbose lifecycle logging via `debugPrint`. Default `false`.
  final bool logging;

  /// App version reported with telemetry (e.g. from package_info). Optional.
  final String? appVersion;

  /// Properties merged into every event's/person's context.
  final Map<String, Object?> defaultProperties;

  String get httpBase => baseUrl.replaceAll(RegExp(r'/+$'), '');
  String get socketBase => (realtimeUrl ?? baseUrl).replaceAll(RegExp(r'/+$'), '');
}
