import 'package:flutter/foundation.dart';

import '../config.dart';
import '../identity.dart';
import '../outbox.dart';
import '../../nexus_platform_interface.dart';

/// Error & crash monitoring. Once [install]ed, it reports **every** uncaught
/// error automatically — Flutter framework errors, uncaught async (Dart) errors,
/// and native crashes (Java/Kotlin, Swift/ObjC, background code). Native crashes
/// are persisted by the native SDK and forwarded on the next launch. Manual
/// [capture] is still available for handled errors.
class NexusErrors {
  NexusErrors(this._outbox, this._id, this._cfg);

  final NexusOutbox _outbox;
  final NexusIdentity _id;
  final NexusConfig _cfg;

  /// Report an error. [handled] = false marks an uncaught crash.
  Future<void> capture(
    Object error, [
    StackTrace? stack,
    Map<String, Object?>? extra,
  ]) {
    final e = Map<String, Object?>.of(extra ?? const {});
    final handled = e.remove('handled') ?? true;
    final level = e.remove('level') ?? 'error';
    return _send(
      type: error.runtimeType.toString(),
      message: error.toString(),
      frames: _parseStack((stack ?? StackTrace.current).toString()),
      handled: handled == true,
      level: level as String,
      context: e,
    );
  }

  Future<void> _send({
    required String type,
    required String message,
    required List<Object?> frames,
    required bool handled,
    required String level,
    Map<String, Object?>? context,
  }) async {
    _outbox.enqueue('/partner/errors', {
      'type': type,
      'message': message,
      'handled': handled,
      'level': level,
      'stack': frames,
      'context': {
        ..._cfg.defaultProperties,
        // App metadata attached to every error to make debugging easier:
        // appName, packageName, version, buildNumber, installerStore,
        // installTime, updateTime, release.
        if (_id.appInfo.isNotEmpty) 'app': _id.appInfo,
        ...?context,
      },
      'release': _id.appInfo['release'] ?? _cfg.appVersion,
      if (_id.distinctId != null) 'distinctId': _id.distinctId,
      'sessionKey': _id.sessionKey,
      'deviceKey': _id.deviceKey,
      ..._id.wireContext,
    });
  }

  /// Install global handlers so **all** uncaught errors are reported, and drain
  /// any native crashes persisted from a previous run.
  void install() {
    // 1) Flutter framework errors (build/layout/paint, gesture callbacks, …).
    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      // Our reporting must never disrupt Flutter's own error handling.
      try {
        capture(details.exception, details.stack, {'handled': false});
      } catch (_) {/* never let the reporter break error handling */}
      prevFlutter?.call(details);
    };

    // 2) Uncaught async / platform-dispatcher errors on this isolate. Returning
    //    false lets the default handler still print to the console.
    final prevPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      try {
        capture(error, stack, {'handled': false});
      } catch (_) {/* never let the reporter break error handling */}
      return prevPlatform?.call(error, stack) ?? false;
    };

    // 3) Native crashes: ask the native SDK to install its uncaught-exception /
    //    signal handlers, and forward any crash it persisted last run.
    NexusPlatform.instance.configureCrashReporting(true);
    _drainNativeCrashes();
  }

  // Symbolication-ready metadata the native reporters attach (for dSYM /
  // ndk-stack resolution on the backend).
  static const _symbolicationKeys = [
    'binaryImages',
    'maps',
    'arch',
    'fault',
    'platform',
  ];

  Future<void> _drainNativeCrashes() async {
    final pending = await NexusPlatform.instance.takePendingCrashes();
    for (final c in pending) {
      final stack = c['stack'];
      await _send(
        type: (c['type'] as String?) ?? 'NativeCrash',
        message: (c['message'] as String?) ?? 'Native crash',
        frames: stack is List ? stack : _parseStack('${stack ?? ''}'),
        handled: false,
        level: 'fatal',
        context: {
          'native': true,
          if (c['timestamp'] != null) 'crashedAt': c['timestamp'],
          for (final k in _symbolicationKeys)
            if (c[k] != null) k: c[k],
        },
      );
    }
  }

  /// Parse a Dart/Flutter stacktrace into structured frames the console renders
  /// as `at <function> (<file>:<line>:<col>)`. Falls back to raw lines.
  static List<Object?> _parseStack(String stack) {
    final frameRe = RegExp(r'^#\d+\s+(.+?)\s+\((.+?):(\d+):(\d+)\)$');
    final out = <Object?>[];
    for (final raw in stack.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final m = frameRe.firstMatch(line);
      if (m != null) {
        out.add({
          'function': m.group(1),
          'filename': m.group(2),
          'lineno': int.tryParse(m.group(3) ?? ''),
          'colno': int.tryParse(m.group(4) ?? ''),
        });
      } else {
        out.add(line); // e.g. "<asynchronous suspension>"
      }
    }
    return out;
  }
}
