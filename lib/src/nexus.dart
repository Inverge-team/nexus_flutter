import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../nexus_platform_interface.dart';
import 'config.dart';
import 'overlay/nexus_auto_overlay.dart';
import 'http_client.dart';
import 'identity.dart';
import 'identity_store.dart';
import 'lifecycle.dart';
import 'logging.dart';
import 'outbox.dart';
import 'services/errors_service.dart';
import 'services/events_service.dart';
import 'services/flags_service.dart';
import 'services/links_service.dart';
import 'services/logs_service.dart';
import 'services/inapp_service.dart';
import 'services/live_activity_service.dart';
import 'services/push_service.dart';
import 'services/realtime_service.dart';
import 'services/remote_config_service.dart';
import 'services/voice_service.dart';
import 'services/replay_service.dart';
import 'services/sessions_service.dart';
import 'services/surveys_service.dart';

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
  NexusAutoOverlay? _autoOverlay;
  void _ensureOverlay() => _autoOverlay?.ensureAttached();
  bool _realtimeWasConnected = false;
  late final NexusSessions sessions;
  late final NexusEvents events;
  late final NexusErrors errors;
  late final NexusLogs logs;
  late final NexusFlags flags;
  late final NexusLinks links;
  late final NexusRealtime realtime;
  late final NexusReplay replay;
  late final NexusSurveys surveys;
  late final NexusRemoteConfig remoteConfig;
  late final NexusPush push;
  late final NexusInApp inApp;
  late final NexusLiveActivity liveActivity;
  late final NexusVoice voice;

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
    await _loadIdentity();
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
    surveys = NexusSurveys(_http, _identity, config);
    remoteConfig = NexusRemoteConfig(_http, _identity, config);
    push = NexusPush(_http, _identity, config);
    inApp = NexusInApp(_http, _identity, config);
    liveActivity = NexusLiveActivity(_http, _identity);
    if (config.liveActivityEnabled) liveActivity.wire();
    voice = NexusVoice(_http, _identity, realtime);
    if (config.voiceEnabled) unawaited(voice.init());
    // Event-triggered surveys + in-app messages fire off analytics events;
    // in-app `event`-action buttons track events back.
    events.onTracked = (name) {
      surveys.onEvent(name);
      inApp.onEvent(name);
    };
    inApp.onTrackEvent = (event) => events.track(event);

    // Auto-mount the survey + in-app overlays (no MaterialApp.builder needed).
    if (config.autoShowOverlay && (config.surveysEnabled || config.inAppEnabled || config.voiceEnabled)) {
      _autoOverlay = NexusAutoOverlay();
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoOverlay?.ensureAttached());
      // Re-attach lazily if a survey/message wants to show before/after a rebuild.
      surveys.current.addListener(_ensureOverlay);
      inApp.current.addListener(_ensureOverlay);
    }

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

    // Fetch eligible surveys once the session is established (best-effort).
    if (config.surveysEnabled) {
      unawaited(surveys.fetch());
    }

    // Turn-key push: permission, token registration, refresh + open tracking.
    if (config.pushEnabled) {
      unawaited(push.start());
    }

    // Fetch in-app messages once the session is established (best-effort).
    if (config.inAppEnabled) {
      unawaited(inApp.fetch());
    }

    // Fetch remote config, and (optionally) subscribe to realtime updates.
    if (config.remoteConfigEnabled) {
      unawaited(remoteConfig.fetch());
    }
    if (config.remoteConfigRealtime &&
        (config.autoConnectRealtime || realtime.isConnected)) {
      unawaited(remoteConfig.subscribeRealtime(realtime));
    }

    // Foreground/background hooks — keeps connection-minutes accurate.
    _lifecycle = NexusLifecycle(
      onBackground: _onBackground,
      onForeground: _onForeground,
    );
    NexusLog.info(
      'ready (${config.autoTrackSessions ? 'session tracking on' : 'session tracking off'})',
    );
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
    // Re-check for newly-eligible surveys + in-app messages.
    if (config.surveysEnabled) unawaited(surveys.fetch());
    if (config.inAppEnabled) unawaited(inApp.fetch());
    // Refresh remote config (values may have changed while backgrounded) and
    // re-arm the realtime subscription if realtime reconnected.
    if (config.remoteConfigEnabled) unawaited(remoteConfig.fetch());
    if (config.remoteConfigRealtime && realtime.isConnected) {
      unawaited(remoteConfig.subscribeRealtime(realtime));
    }
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
    } catch (_) {
      /* fall back to the per-launch key */
    }
  }

  /// Restore the identified end-user persisted by a previous [identify] so this
  /// launch continues as that user — every session is then attributed to them.
  /// If nothing was ever identified, stays anonymous (the default behavior).
  Future<void> _loadIdentity() async {
    final stored = await IdentityStore.load();
    if (stored == null) return;
    _identity.distinctId = stored.distinctId;
    _identity.traits.addAll(stored.traits);
    NexusLog.info('restored identity — distinctId=${stored.distinctId}');
  }

  /// Assemble app metadata (name/package/version/build/installer + install/
  /// update time) from the native device-info channel, then derive `appVersion`.
  ///
  /// Deliberately avoids `package_info_plus`: it imports `dart:io` (and `win32`
  /// on Windows), which breaks WASM compatibility and muddies per-platform
  /// analysis. The native layer already surfaces these fields.
  Future<void> _loadAppInfo() async {
    final app = <String, Object?>{};
    final dc = _identity.deviceContext;
    for (final k in [
      'appName',
      'packageName',
      'version',
      'buildNumber',
      'installerStore',
      'installTime',
      'updateTime',
    ]) {
      final v = dc[k];
      if (v != null) app[k] = v;
      dc.remove(k); // keep these under `app`, not top-level
    }
    app.removeWhere((_, v) => v == null || (v is String && v.isEmpty));

    final version = app['version'] as String?;
    final build = app['buildNumber'] as String?;
    final release =
        config.appVersion ??
        dc['appVersion'] as String? ??
        (version != null
            ? (build != null && build.isNotEmpty ? '$version+$build' : version)
            : null);
    if (release != null) {
      dc['appVersion'] = release;
      app['release'] = release;
    }
    _identity.appInfo = app;
  }

  /// Identify the current end-user (shorthand for `sessions.identify`).
  Future<void> identify(
    String distinctId, {
    String? email,
    String? name,
    String? phone,
    Map<String, Object?>? traits,
  }) => sessions.identify(
    distinctId,
    email: email,
    name: name,
    phone: phone,
    traits: traits,
  );

  /// Forget the current user and start a fresh session (e.g. on logout). Also
  /// clears the persisted identity so the next launch starts anonymous.
  Future<void> reset() => sessions.reset();

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
    surveys.current.removeListener(_ensureOverlay);
    inApp.current.removeListener(_ensureOverlay);
    _autoOverlay?.detach();
    surveys.dispose();
    inApp.dispose();
    remoteConfig.dispose();
    unawaited(push.dispose());
    realtime.disconnect();
    _outbox.dispose();
    _http.close();
    if (identical(_instance, this)) _instance = null;
  }
}
