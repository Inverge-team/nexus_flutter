import 'dart:math';

import '../config.dart';
import '../identity.dart';
import '../logging.dart';
import '../outbox.dart';
import '../replay/replay_controller.dart';
import '../../nexus_platform_interface.dart';
import 'batch_queue.dart';

/// Session replay. Captures the app as rrweb-compatible screenshot frames +
/// pointer events via [NexusReplayController] (Flutter-side, all platforms) and
/// ships them to `/partner/replay`, correlated to the session. Also accepts
/// batches from a native recorder if one is present (future native SDKs).
class NexusReplay {
  NexusReplay(this._outbox, this._id, this._cfg) {
    _queue = BatchQueue<Object?>(
      maxBatch: 200,
      interval: _cfg.flushInterval,
      onFlush: _flush,
    );
    _controller = NexusReplayController(_cfg, _onEvent);
    // Native recorder path (no-op until a native SDK implements capture).
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
  late final NexusReplayController _controller;

  String? _recordingId;
  bool _recording = false;
  int? _width;
  int? _height;

  bool get isRecording => _recording;

  /// The Flutter capture engine — used by [NexusScope] to install the
  /// RepaintBoundary and forward pointer events. Internal.
  NexusReplayController get controller => _controller;

  /// Start capturing the session.
  Future<void> start() async {
    if (_recording) return;
    _recording = true;
    _recordingId ??= 'rec_${_randomHex()}';
    _controller.start();
    // Harmless when native capture is a no-op; enables it once implemented.
    await NexusPlatform.instance.startReplay(_recordingId!);
  }

  /// Stop capturing and flush any buffered events.
  Future<void> stop() async {
    if (!_recording) return;
    _recording = false;
    _controller.stop();
    await NexusPlatform.instance.stopReplay();
    await _queue.flush();
  }

  /// Pause/resume capture (called around app background/foreground).
  void pause() => _controller.pause();
  void resume() => _controller.resume();

  Future<void> flush() => _queue.flush();

  /// Receive one rrweb event from the Flutter capture engine.
  void _onEvent(Map<String, Object?> event) {
    if (event['type'] == 4) {
      final data = event['data'];
      if (data is Map) {
        _width = (data['width'] as num?)?.toInt();
        _height = (data['height'] as num?)?.toInt();
      }
    }
    _queue.add(event);
  }

  Future<void> _flush(List<Object?> events) async {
    final rec = _recordingId;
    if (rec == null || events.isEmpty) return;
    _outbox.enqueue('/partner/replay', {
      'recordingId': rec,
      'events': events,
      if (_id.distinctId != null) 'distinctId': _id.distinctId,
      'sessionKey': _id.sessionKey,
      'deviceKey': _id.deviceKey,
      if (_width != null) 'width': _width,
      if (_height != null) 'height': _height,
      ..._id.wireContext,
    });
    NexusLog.debug('replay: shipped ${events.length} events for $rec');
  }

  void dispose() {
    _controller.dispose();
    _queue.dispose();
  }

  static String _randomHex() {
    final r = Random.secure();
    return List<int>.generate(8, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
