import '../config.dart';
import '../http_client.dart';
import '../identity.dart';
import 'batch_queue.dart';

/// Product analytics. Events are buffered and shipped in batches, correlated to
/// the current session.
class NexusEvents {
  NexusEvents(this._http, this._id, this._cfg) {
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

  /// Track a named event with optional properties.
  void track(String name, {Map<String, Object?>? properties}) {
    _queue.add({
      'name': name,
      if (properties != null || _cfg.defaultProperties.isNotEmpty)
        'properties': {..._cfg.defaultProperties, ...?properties},
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> flush() => _queue.flush();

  Future<void> _flush(List<Map<String, Object?>> events) async {
    await _http.post('/partner/events', {
      'events': events,
      if (_id.distinctId != null) 'distinctId': _id.distinctId,
      'sessionKey': _id.sessionKey,
      'deviceKey': _id.deviceKey,
      'appVersion': _cfg.appVersion,
      ..._id.deviceContext,
    });
  }

  void dispose() => _queue.dispose();
}
