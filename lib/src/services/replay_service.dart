import 'dart:math';

import '../config.dart';
import '../identity.dart';
import '../outbox.dart';
import '../../nexus_platform_interface.dart';
import 'batch_queue.dart';

/// Session replay. Native SDKs (Android/iOS) capture rrweb-compatible event
/// batches and push them up; this service ships them to `/partner/replay`,
/// correlated to the session. Falls back to a no-op where native capture isn't
/// available yet (web/desktop).
class NexusReplay {
  NexusReplay(this._outbox, this._id, this._cfg) {
    _queue = BatchQueue<Object?>(
      maxBatch: 200,
      interval: _cfg.flushInterval,
      onFlush: _flush,
    );
    NexusPlatform.instance.onReplayBatch((recordingId, events) {
      _recordingId = recordingId;
      for (final e in events) {
        _queue.add(e);
      }
    });
  }

  final NexusOutbox _outbox;
  final NexusIdentity _id;
  final NexusConfig _cfg;
  late final BatchQueue<Object?> _queue;

  String? _recordingId;
  bool _recording = false;

  bool get isRecording => _recording;

  /// Start capturing the session on the native layer.
  Future<void> start() async {
    if (_recording) return;
    _recording = true;
    _recordingId ??= 'rec_${_randomHex()}';
    await NexusPlatform.instance.startReplay(_recordingId!);
  }

  /// Stop capturing and flush any buffered events.
  Future<void> stop() async {
    if (!_recording) return;
    _recording = false;
    await NexusPlatform.instance.stopReplay();
    await _queue.flush();
  }

  Future<void> flush() => _queue.flush();

  Future<void> _flush(List<Object?> events) async {
    final rec = _recordingId;
    if (rec == null || events.isEmpty) return;
    _outbox.enqueue('/partner/replay', {
      'recordingId': rec,
      'events': events,
      if (_id.distinctId != null) 'distinctId': _id.distinctId,
      'sessionKey': _id.sessionKey,
      'deviceKey': _id.deviceKey,
      ..._id.wireContext,
    });
  }

  void dispose() => _queue.dispose();

  static String _randomHex() {
    final r = Random.secure();
    return List<int>.generate(8, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
