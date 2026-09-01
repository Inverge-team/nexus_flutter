/// Nexus — one Flutter SDK for all Inverge Nexus services.
///
/// Initialise once, then use any service (all correlated to one session):
///
/// ```dart
/// await Nexus.init(const NexusConfig(apiKey: 'nxs_...'));
/// runApp(NexusScope(child: MyApp()));
/// // …
/// context.nexus.events.track('signed_up');
/// context.nexus.realtime.join('orders:42');
/// ```
library;

export 'src/nexus.dart' show Nexus;
export 'src/config.dart' show NexusConfig;
export 'src/logging.dart' show NexusLog, NexusLogLevel, NexusLogSink;
export 'src/context.dart' show NexusScope, NexusBuildContext;

export 'src/services/sessions_service.dart' show NexusSessions;
export 'src/services/events_service.dart' show NexusEvents;
export 'src/services/errors_service.dart' show NexusErrors;
export 'src/services/logs_service.dart' show NexusLogs;
export 'src/services/flags_service.dart' show NexusFlags;
export 'src/services/links_service.dart' show NexusLinks;
export 'src/services/realtime_service.dart' show NexusRealtime, NexusEventHandler;
export 'src/services/replay_service.dart' show NexusReplay;

// Advanced: native platform surface (device info + replay capture).
export 'nexus_platform_interface.dart' show NexusPlatform;
