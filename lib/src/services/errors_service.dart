import 'package:flutter/foundation.dart';

import '../config.dart';
import '../http_client.dart';
import '../identity.dart';

/// Error monitoring. Captures thrown errors (with stacktrace) and — when
/// installed — Flutter's uncaught framework/isolate errors, correlated to the
/// session.
class NexusErrors {
  NexusErrors(this._http, this._id, this._cfg);

  final NexusHttp _http;
  final NexusIdentity _id;
  final NexusConfig _cfg;

  /// Report an error. [handled] = false marks an uncaught crash.
  Future<void> capture(
    Object error, [
    StackTrace? stack,
    Map<String, Object?>? extra,
  ]) async {
    await _http.post('/partner/errors', {
      'type': error.runtimeType.toString(),
      'message': error.toString(),
      'handled': extra?['handled'] ?? true,
      'level': extra?['level'] ?? 'error',
      'stack': (stack ?? StackTrace.current).toString().split('\n'),
      'context': {
        ..._cfg.defaultProperties,
        if (extra != null) ...extra..remove('handled')..remove('level'),
      },
      'release': _cfg.appVersion,
      if (_id.distinctId != null) 'distinctId': _id.distinctId,
      'sessionKey': _id.sessionKey,
      'deviceKey': _id.deviceKey,
      ..._id.deviceContext,
    });
  }

  /// Install global handlers so uncaught Flutter/isolate errors are reported.
  void install() {
    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      capture(details.exception, details.stack, {'handled': false});
      prevFlutter?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      capture(error, stack, {'handled': false});
      return false;
    };
  }
}
