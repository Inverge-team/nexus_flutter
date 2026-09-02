import '../config.dart';
import '../identity.dart';
import '../outbox.dart';
import 'batch_queue.dart';

/// Product analytics. Events are buffered, batched, and handed to the durable
/// outbox — correlated to the current session and retried until delivered.
class NexusEvents {
  NexusEvents(this._outbox, this._id, this._cfg) {
    _queue = BatchQueue<Map<String, Object?>>(
      maxBatch: _cfg.maxBatch,
      interval: _cfg.flushInterval,
      onFlush: _flush,
    );
  }

  final NexusOutbox _outbox;
  final NexusIdentity _id;
  final NexusConfig _cfg;
  late final BatchQueue<Map<String, Object?>> _queue;

  /// Notified with each tracked event name (used to fire survey event triggers).
  void Function(String name)? onTracked;

  /// Track a named event with optional properties.
  void track(String name, {Map<String, Object?>? properties}) {
    onTracked?.call(name);
    _queue.add({
      'name': name,
      if (properties != null || _cfg.defaultProperties.isNotEmpty)
        'properties': {..._cfg.defaultProperties, ...?properties},
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> flush() => _queue.flush();

  Future<void> _flush(List<Map<String, Object?>> events) async {
    _outbox.enqueue('/partner/events', {
      'events': events,
      if (_id.distinctId != null) 'distinctId': _id.distinctId,
      'sessionKey': _id.sessionKey,
      'deviceKey': _id.deviceKey,
      'appVersion': _cfg.appVersion,
      ..._id.wireContext,
    });
  }

  void dispose() => _queue.dispose();
}
