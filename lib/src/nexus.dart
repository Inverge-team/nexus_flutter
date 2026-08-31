import '../nexus_platform_interface.dart';
import 'config.dart';
import 'http_client.dart';
import 'identity.dart';
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
    _identity.deviceContext = await NexusPlatform.instance.deviceInfo();
    if (config.appVersion != null) {
      _identity.deviceContext['appVersion'] = config.appVersion;
    }
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

    if (config.autoCaptureErrors) errors.install();
    if (config.autoTrackSessions) await sessions.track();
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
    events.dispose();
    logs.dispose();
    replay.dispose();
    realtime.disconnect();
    _outbox.dispose();
    _http.close();
    if (identical(_instance, this)) _instance = null;
  }
}
