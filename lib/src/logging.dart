import 'package:flutter/foundation.dart';

/// Verbosity of the SDK's diagnostic logging.
///
/// Higher levels include everything below them. The default is [warn] — silent
/// in the happy path, but surfacing dropped telemetry / failed requests so
/// problems (like a rejected session) never fail silently. Set
/// `NexusConfig(logLevel: NexusLogLevel.debug)` (or `logging: true`) to trace
/// every request while integrating.
enum NexusLogLevel { none, error, warn, info, debug }

/// A custom log sink — receive every record the SDK emits (e.g. to forward it
/// into your own logging, or into Nexus Logs). Set via `NexusConfig.onLog`.
typedef NexusLogSink = void Function(
  NexusLogLevel level,
  String message, [
  Object? error,
  StackTrace? stackTrace,
]);

/// Central, leveled logger for the SDK. Configured once from [NexusConfig] at
/// `Nexus.init`; every component logs through the static methods so output is
/// consistent (`[Nexus] HH:mm:ss.SSS LEVEL message`) and centrally gated.
///
/// Uses `debugPrint` (rate-limited, not stripped in profile builds) rather than
/// `print`, and additionally fans out to an optional [NexusLogSink].
class NexusLog {
  NexusLog._();

  /// Active level. Below this, calls are cheap no-ops.
  static NexusLogLevel level = NexusLogLevel.warn;

  /// Optional extra sink (in addition to `debugPrint`).
  static NexusLogSink? sink;

  static const _prefix = '[Nexus]';

  /// Apply configuration from [NexusConfig]. Called at the start of init.
  static void configure({NexusLogLevel? level, NexusLogSink? sink}) {
    if (level != null) NexusLog.level = level;
    NexusLog.sink = sink;
  }

  static bool _enabled(NexusLogLevel l) =>
      level != NexusLogLevel.none && level.index >= l.index;

  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    if (_enabled(NexusLogLevel.error)) _emit(NexusLogLevel.error, message, error, stackTrace);
  }

  static void warn(String message) {
    if (_enabled(NexusLogLevel.warn)) _emit(NexusLogLevel.warn, message);
  }

  static void info(String message) {
    if (_enabled(NexusLogLevel.info)) _emit(NexusLogLevel.info, message);
  }

  static void debug(String message) {
    if (_enabled(NexusLogLevel.debug)) _emit(NexusLogLevel.debug, message);
  }

  static void _emit(NexusLogLevel l, String message, [Object? error, StackTrace? stackTrace]) {
    final s = sink;
    if (s != null) {
      try {
        s(l, message, error, stackTrace);
      } catch (_) {/* a broken sink must never break the app */}
    }
    final ts = DateTime.now().toIso8601String().split('T').last; // HH:mm:ss.SSSZ
    debugPrint('$_prefix ${ts.substring(0, 12)} ${_label(l)} $message');
    if (error != null) debugPrint('$_prefix            ↳ $error');
    if (stackTrace != null && l == NexusLogLevel.error) {
      debugPrint('$_prefix            ↳ $stackTrace');
    }
  }

  static String _label(NexusLogLevel l) {
    switch (l) {
      case NexusLogLevel.error:
        return 'ERROR';
      case NexusLogLevel.warn:
        return 'WARN ';
      case NexusLogLevel.info:
        return 'INFO ';
      case NexusLogLevel.debug:
        return 'DEBUG';
      case NexusLogLevel.none:
        return '     ';
    }
  }

  /// Mask a secret for logs: keep a readable prefix + last 4 chars.
  static String mask(String secret) {
    if (secret.length <= 12) return '${secret.isEmpty ? '' : secret[0]}***';
    return '${secret.substring(0, 8)}…${secret.substring(secret.length - 4)}';
  }
}
