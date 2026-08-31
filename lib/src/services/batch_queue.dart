import 'dart:async';

/// Buffers items and flushes them in batches — on reaching [maxBatch], on a
/// timer, or on demand. Used by the events and logs services.
class BatchQueue<T> {
  BatchQueue({
    required this.maxBatch,
    required this.interval,
    required this.onFlush,
  });

  final int maxBatch;
  final Duration interval;
  final Future<void> Function(List<T> batch) onFlush;

  final List<T> _buffer = [];
  Timer? _timer;

  void add(T item) {
    _buffer.add(item);
    _timer ??= Timer.periodic(interval, (_) => flush());
    if (_buffer.length >= maxBatch) flush();
  }

  Future<void> flush() async {
    if (_buffer.isEmpty) return;
    final batch = List<T>.from(_buffer);
    _buffer.clear();
    try {
      await onFlush(batch);
    } catch (_) {
      // Swallow — telemetry must never surface to the app.
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    flush();
  }
}
