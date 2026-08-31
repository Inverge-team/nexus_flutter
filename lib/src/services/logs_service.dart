import '../config.dart';
import '../http_client.dart';
import '../identity.dart';
import 'batch_queue.dart';

/// Structured logging. Lines are buffered and shipped in batches, correlated to
/// the current session.
class NexusLogs {
  NexusLogs(this._http, this._id, this._cfg) {
    _queue = BatchQueue<Map<String, Object?>>(
      maxBatch: _cfg.maxBatch,
      interval: _cfg.flushInterval,
      onFlush: _flush,
    );
  }

  final NexusHttp _http;
  final NexusIdentity _id;
  final NexusConfig _cfg;
  late final BatchQueue<Map<String, Object?>> _queue;

  void trace(String message, {String? source, Map<String, Object?>? context}) => _log('trace', message, source, context);
  void debug(String message, {String? source, Map<String, Object?>? context}) => _log('debug', message, source, context);
  void info(String message, {String? source, Map<String, Object?>? context}) => _log('info', message, source, context);
  void warn(String message, {String? source, Map<String, Object?>? context}) => _log('warn', message, source, context);
  void error(String message, {String? source, Map<String, Object?>? context}) => _log('error', message, source, context);

  void _log(String level, String message, String? source, Map<String, Object?>? context) {
    _queue.add({
      'level': level,
      'message': message,
      if (source != null) 'source': source,
      if (context != null) 'context': context,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> flush() => _queue.flush();

  Future<void> _flush(List<Map<String, Object?>> logs) async {
    await _http.post('/partner/logs', {
      'logs': logs,
      if (_id.distinctId != null) 'distinctId': _id.distinctId,
      'sessionKey': _id.sessionKey,
      'deviceKey': _id.deviceKey,
      'appVersion': _cfg.appVersion,
      ..._id.deviceContext,
    });
  }

  void dispose() => _queue.dispose();
}
