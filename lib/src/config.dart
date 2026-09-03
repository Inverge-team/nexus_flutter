import 'logging.dart';

/// Configuration for [Nexus.init].
class NexusConfig {
  const NexusConfig({
    required this.apiKey,
    this.baseUrl = 'https://nexus.inverge.net',
    this.realtimeUrl,
    this.autoTrackSessions = true,
    this.autoCaptureErrors = true,
    this.autoConnectRealtime = false,
    this.manageRealtimeWithLifecycle = true,
    this.flushOnBackground = true,
    this.flushInterval = const Duration(seconds: 10),
    this.maxBatch = 50,
    this.logging = false,
    this.logLevel,
    this.onLog,
    this.replayEnabled = false,
    this.replayInterval = const Duration(milliseconds: 1000),
    this.replayPixelRatio = 1.0,
    this.replayMaskTextFields = true,
    this.replayCaptureConsole = true,
    this.replayCaptureNetwork = true,
    this.surveysEnabled = false,
    this.surveyAutoShow = true,
    this.remoteConfigEnabled = false,
    this.remoteConfigRealtime = false,
    this.remoteConfigDefaults = const {},
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

  /// Open the realtime (Socket.IO) connection automatically at startup, right
  /// after the session is established — so the user is live without a manual
  /// `nexus.realtime.connect()`. Rooms are still joined via
  /// `nexus.realtime.join(...)`. Default `false` (realtime connection-minutes
  /// are billed — opt in). Works with [manageRealtimeWithLifecycle].
  final bool autoConnectRealtime;

  /// Gracefully disconnect realtime when the app is backgrounded and reconnect
  /// (rejoining rooms) on foreground. This makes billed connection-minutes
  /// accurate — the app isn't charged while suspended. Default `true`.
  final bool manageRealtimeWithLifecycle;

  /// Flush queued telemetry when the app is backgrounded (so nothing is lost if
  /// the OS kills the app). Default `true`.
  final bool flushOnBackground;

  /// How often batched telemetry (events/logs) is flushed. Default 10s.
  final Duration flushInterval;

  /// Max items per batch flush. Default 50.
  final int maxBatch;

  /// Shorthand for verbose logging: `true` maps to [NexusLogLevel.debug].
  /// Prefer [logLevel] for finer control. Default `false`.
  final bool logging;

  /// Diagnostic log verbosity. When null, falls back to [logging] (`debug` if
  /// on) and otherwise [NexusLogLevel.warn] — so failed requests and dropped
  /// telemetry are always visible, while the happy path stays quiet.
  final NexusLogLevel? logLevel;

  /// Optional sink to receive every log record (in addition to `debugPrint`),
  /// e.g. to forward SDK diagnostics into your own logging.
  final NexusLogSink? onLog;

  /// Record session replay: periodic screenshots of the app + pointer events,
  /// shipped as rrweb frames. Requires wrapping the app in `NexusScope`. Wrap
  /// sensitive widgets in `NexusMask` to redact them. Default `false` (billed /
  /// privacy-sensitive — opt in explicitly).
  final bool replayEnabled;

  /// How often a replay frame is captured. Lower = smoother but more data/CPU.
  /// Default 1s. Identical consecutive frames are dropped automatically.
  final Duration replayInterval;

  /// Capture resolution as a multiple of logical pixels. 1.0 ≈ device-independent
  /// resolution (small, fast); raise toward `MediaQuery.devicePixelRatio` for
  /// crisper frames, lower (e.g. 0.75) to shrink payloads. Default 1.0.
  final double replayPixelRatio;

  /// Automatically redact every text input (anything backed by `EditableText` —
  /// `TextField`, `TextFormField`, `CupertinoTextField`, `SelectableText`) from
  /// replay frames, so typed content (passwords, PII) is never captured. On by
  /// default; use `NexusMask` for finer control. Set `false` to opt out.
  final bool replayMaskTextFields;

  /// Tee the app's `debugPrint` output into the replay stream so it shows in the
  /// player's Console tab (mirrors rrweb's console plugin). SDK-internal
  /// `[Nexus]` lines are skipped. On by default; set `false` to opt out.
  final bool replayCaptureConsole;

  /// Automatically capture HTTP requests for the player's Network tab via
  /// `HttpOverrides` — covers **both Dio and `package:http`** (any `dart:io`
  /// client) with no wiring. Requests to the Nexus API are excluded. On by
  /// default (no effect on web — use a Dio interceptor there). Set `false` to
  /// opt out (e.g. if the app installs its own `HttpOverrides`).
  final bool replayCaptureNetwork;

  /// Fetch eligible in-product surveys at startup (and on foreground). Requires
  /// `NexusSurveyOverlay` in your `MaterialApp.builder` to display them. Default
  /// `false` (billed per response — opt in).
  final bool surveysEnabled;

  /// Automatically show eligible popover/banner surveys (and event-triggered
  /// ones on `events.track`). Set `false` to present surveys manually via
  /// `nexus.surveys.show(...)`. Default `true`.
  final bool surveyAutoShow;

  /// Fetch Remote Config at startup (and on foreground). Read values via
  /// `nexus.remoteConfig.getString(...)` etc. Default `false` (billed per fetch
  /// — opt in). Set in-app fallbacks with [remoteConfigDefaults].
  final bool remoteConfigEnabled;

  /// Subscribe to realtime Remote Config updates: when a new template is
  /// published, the app re-fetches automatically (Firebase Realtime RC). Needs
  /// a realtime connection (see [autoConnectRealtime]). Default `false`.
  final bool remoteConfigRealtime;

  /// In-app default Remote Config values, used until/unless the server provides
  /// a value for a key. Mirrors Firebase `setDefaults`.
  final Map<String, Object?> remoteConfigDefaults;

  /// App version reported with telemetry (e.g. from package_info). Optional.
  final String? appVersion;

  /// Properties merged into every event's/person's context.
  final Map<String, Object?> defaultProperties;

  /// Effective log level: explicit [logLevel], else `debug` when [logging] is
  /// on, else `warn`.
  NexusLogLevel get resolvedLogLevel =>
      logLevel ?? (logging ? NexusLogLevel.debug : NexusLogLevel.warn);

  String get httpBase => baseUrl.replaceAll(RegExp(r'/+$'), '');
  String get socketBase => (realtimeUrl ?? baseUrl).replaceAll(RegExp(r'/+$'), '');
}
