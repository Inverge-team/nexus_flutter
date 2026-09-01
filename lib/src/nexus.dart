import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../nexus_platform_interface.dart';
import 'config.dart';
import 'http_client.dart';
import 'identity.dart';
import 'lifecycle.dart';
import 'logging.dart';
import 'outbox.dart';
import 'services/errors_service.dart';
import 'services/events_service.dart';
import 'services/flags_service.dart';
import 'services/links_service.dart';
import 'services/logs_service.dart';
import 'services/realtime_service.dart';
import 'services/replay_service.dart';
import 'services/sessions_service.dart';

/// The Nexus umbrella SDK — one entry point for every service. Initialise once
/// at startup; then use any service, all correlated to the same journey session:
///
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Nexus.init(const NexusConfig(apiKey: 'nxs_...'));
///   runApp(NexusScope(child: MyApp()));
/// }
///
/// // anywhere with a BuildContext:
/// context.nexus.events.track('order_placed');
/// context.nexus.realtime.join('orders:42');
/// ```
class Nexus {
  Nexus._(this.config) : _identity = NexusIdentity();

  static Nexus? _instance;

  /// The app-wide instance. Throws if [init] hasn't run.
  static Nexus get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('Nexus.init() must be called before using the SDK.');
    }
    return i;
  }

  static bool get isInitialized => _instance != null;

  final NexusConfig config;
  final NexusIdentity _identity;

  late final NexusHttp _http;
  late final NexusOutbox _outbox;
  NexusLifecycle? _lifecycle;
  bool _realtimeWasConnected = false;
  late final NexusSessions sessions;
  late final NexusEvents events;
  late final NexusErrors errors;
  late final NexusLogs logs;
  late final NexusFlags flags;
  late final NexusLinks links;
  late final NexusRealtime realtime;
  late final NexusReplay replay;

  /// Initialise the SDK once at startup. Re-calling disposes the previous
  /// instance and replaces it.
  static Future<Nexus> init(NexusConfig config) async {
    _instance?.dispose();
    final n = Nexus._(config);
    await n._boot();
    _instance = n;
    return n;
  }

  Future<void> _boot() async {
    NexusLog.configure(level: config.resolvedLogLevel, sink: config.onLog);
    NexusLog.info(
      'initialising — base=${config.httpBase}, apiKey=${NexusLog.mask(config.apiKey)}',
    );

    _identity.deviceContext = await NexusPlatform.instance.deviceInfo();
    await _loadDeviceKey();
    await _loadAppInfo();
    NexusLog.debug(
      'identity ready — deviceKey=${_identity.deviceKey}, '
      'os=${_identity.deviceContext['osType']} ${_identity.deviceContext['osVersion']}, '
      'appVersion=${_identity.deviceContext['appVersion']}',
    );
    _http = NexusHttp(config, _identity);
    _outbox = NexusOutbox(_http, config);
    await _outbox.init();

    // Request/response services use HTTP directly; fire-and-forget telemetry
    // goes through the durable outbox (persisted + retried).
    sessions = NexusSessions(_http, _identity, config);
    events = NexusEvents(_outbox, _identity, config);
    errors = NexusErrors(_outbox, _identity, config);
    logs = NexusLogs(_outbox, _identity, config);
    flags = NexusFlags(_http, _identity, config);
    links = NexusLinks(_http, _identity);
    realtime = NexusRealtime(config, _identity);
    replay = NexusReplay(_outbox, _identity, config);

    if (config.autoCaptureErrors) {
      errors.install();
      NexusLog.debug('automatic error capture installed');
    }
    if (config.autoTrackSessions) {
      await sessions.track();
    } else {
      NexusLog.debug('autoTrackSessions is off — no session started');
    }

    // Go live once the session/identity is set, so realtime auth carries it.
    if (config.autoConnectRealtime) {
      realtime.connect();
      _realtimeWasConnected = true;
      NexusLog.info('realtime auto-connecting');
    }

    if (config.replayEnabled) {
      await replay.start();
      NexusLog.info('session replay enabled');
    }

    // Foreground/background hooks — keeps connection-minutes accurate.
    _lifecycle = NexusLifecycle(onBackground: _onBackground, onForeground: _onForeground);
    NexusLog.info('ready (${config.autoTrackSessions ? 'session tracking on' : 'session tracking off'})');
  }

  Future<void> _onBackground() async {
    NexusLog.debug('app backgrounded — flushing telemetry');
    if (config.replayEnabled) replay.pause(); // can't rasterize a suspended app
    _realtimeWasConnected = realtime.isConnected;
    // Graceful disconnect → the server meters the exact connected duration
    // instead of over-counting until a ping timeout while the app is suspended.
    if (config.manageRealtimeWithLifecycle && realtime.isConnected) {
      realtime.disconnect();
    }
    if (config.flushOnBackground) await flush();
  }

  Future<void> _onForeground() async {
    NexusLog.debug('app foregrounded');
    if (config.replayEnabled) replay.resume();
    if (config.autoTrackSessions) await sessions.track();
    // Reconnect only if realtime was in use before backgrounding (rooms rejoin
    // automatically).
    if (config.manageRealtimeWithLifecycle && _realtimeWasConnected) {
      realtime.connect();
    }
    // Retry any telemetry that queued while offline/suspended.
    await _outbox.drain();
  }

  /// A stable, per-install device id — generated once and persisted (natively,
  /// via shared_preferences). Survives restarts; reset on reinstall.
  Future<void> _loadDeviceKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('nexus_device_key');
      if (stored != null && stored.isNotEmpty) {
        _identity.deviceKey = stored;
      } else {
        await prefs.setString('nexus_device_key', _identity.deviceKey);
      }
    } catch (_) {/* fall back to the per-launch key */}
  }

  /// Auto-detect app metadata (name/package/version/build/installer) and, from
  /// the native layer, install/update time — then derive `appVersion`.
  Future<void> _loadAppInfo() async {
    final app = <String, Object?>{};
    try {
      final pkg = await PackageInfo.fromPlatform();
      app.addAll({
        'appName': pkg.appName,
        'packageName': pkg.packageName,
        'version': pkg.version,
        'buildNumber': pkg.buildNumber,
        'installerStore': pkg.installerStore,
      });
    } catch (_) {/* unavailable in tests / some platforms */}

    // Native install/update time + installer (Android exact; iOS best-effort).
    for (final k in ['installTime', 'updateTime', 'installerStore']) {
      final v = _identity.deviceContext[k];
      if (v != null) app[k] = v;
      _identity.deviceContext.remove(k); // keep these under `app`, not top-level
    }
    app.removeWhere((_, v) => v == null || (v is String && v.isEmpty));

    final version = app['version'] as String?;
    final build = app['buildNumber'] as String?;
    final release = config.appVersion ??
        (version != null ? (build != null && build.isNotEmpty ? '$version+$build' : version) : null);
    if (release != null) {
      _identity.deviceContext['appVersion'] = release;
      app['release'] = release;
    }
    _identity.appInfo = app;
  }

  /// Identify the current end-user (shorthand for `sessions.identify`).
  Future<void> identify(
    String distinctId, {
    String? email,
    String? name,
    Map<String, Object?>? traits,
  }) => sessions.identify(distinctId, email: email, name: name, traits: traits);

  /// Forget the current user and start a fresh session (e.g. on logout).
  void reset() => sessions.reset();

  /// Record a screen/page change for session replay's Pages tab. Wire
  /// [NexusNavigatorObserver] into `navigatorObservers` to do this automatically.
  void trackScreen(String name) => replay.trackScreen(name);

  /// Track navigation from a [Listenable] router (e.g. GoRouter's
  /// `routerDelegate`) — catches shell/nested routes a root observer misses.
  /// See [NexusReplay.observeRouter].
  void observeRouter(Listenable router, String Function() currentPath) =>
      replay.observeRouter(router, currentPath);

  String? get distinctId => _identity.distinctId;
  String get sessionKey => _identity.sessionKey;

  /// Flush all buffered telemetry into the outbox and try to deliver it now
  /// (call before the app is backgrounded/killed).
  Future<void> flush() async {
    await events.flush();
    await logs.flush();
    await replay.flush();
    await _outbox.drain();
  }

  /// Number of telemetry requests awaiting delivery (queued/offline).
  int get pendingUploads => _outbox.pending;

  /// Tear down the instance (timers, socket, http).
  void dispose() {
    _lifecycle?.dispose();
    events.dispose();
    logs.dispose();
    replay.dispose();
    realtime.disconnect();
    _outbox.dispose();
    _http.close();
    if (identical(_instance, this)) _instance = null;
  }
}
