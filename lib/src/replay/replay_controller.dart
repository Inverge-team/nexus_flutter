import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../config.dart';
import '../logging.dart';
import 'replay_mask.dart';
import 'rrweb.dart';

/// Sink for produced rrweb events (wired to the replay upload queue).
typedef ReplayEventSink = void Function(Map<String, Object?> event);

/// Flutter-side session-replay capture: on a timer it rasterises the app's
/// [RepaintBoundary] to a screenshot, redacts any [NexusMask] regions, and emits
/// rrweb events (full snapshot then per-frame `img` mutations). Pointer events
/// fed from [NexusScope]'s `Listener` become rrweb interactions.
///
/// Cross-platform by construction — it captures the rendered pixels, so it needs
/// no per-platform native view-tree serialization.
class NexusReplayController {
  NexusReplayController(this._cfg, this._emit);

  final NexusConfig _cfg;
  final ReplayEventSink _emit;

  /// Installed by [NexusScope] on the RepaintBoundary that wraps the app.
  final GlobalKey repaintBoundaryKey = GlobalKey();

  Timer? _timer;
  bool _recording = false;
  bool _paused = false;
  bool _sentFirst = false;
  bool _capturing = false;
  bool _warnedNoScope = false;
  int? _lastHash;
  int? _lastW;
  int? _lastH;
  String _currentHref = 'app:///';
  DebugPrintCallback? _originalDebugPrint;

  // Pointer-move batching (rrweb expects grouped move positions).
  final List<Map<String, Object?>> _moveBuffer = [];
  Timer? _moveTimer;

  bool get isRecording => _recording;

  void start() {
    if (_recording) return;
    _recording = true;
    _paused = false;
    _sentFirst = false;
    _lastHash = null;
    _installConsoleCapture();
    _timer = Timer.periodic(_cfg.replayInterval, (_) => _tick());
    NexusLog.info('replay recording started (frame every ${_cfg.replayInterval.inMilliseconds}ms)');
    // First frame after the next frame is committed — by then NexusScope (added
    // in runApp, right after Nexus.init) is mounted, so we avoid a false warning.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
  }

  void stop() {
    if (!_recording) return;
    _recording = false;
    _timer?.cancel();
    _timer = null;
    _flushMoves();
    _restoreConsoleCapture();
    NexusLog.debug('replay recording stopped');
  }

  /// Record a page/route change — populates the player's Pages tab. Called by
  /// [NexusNavigatorObserver] or manually via `nexus.trackScreen(name)`.
  void trackScreen(String name) {
    final clean = name.replaceFirst(RegExp(r'^/+'), '');
    _currentHref = 'app:///$clean';
    // Emit now if we know the viewport (a meta must carry it so the player
    // doesn't resize to 0); otherwise the first frame will use this href.
    if (_sentFirst && _lastW != null && _lastH != null) {
      _emit(Rrweb.meta(href: _currentHref, width: _lastW!, height: _lastH!));
      NexusLog.debug('replay: page → $_currentHref');
    }
  }

  /// Record a network request — populates the player's Network tab.
  void recordNetwork({
    required String url,
    required String method,
    required int status,
    required int durationMs,
    int? size,
  }) {
    if (!_recording) return;
    _emit(Rrweb.network(url: url, method: method, status: status, duration: durationMs, size: size));
  }

  void pause() => _paused = true;
  void resume() => _paused = false;

  /// Capture a single frame immediately, bypassing the timer. Testing only.
  @visibleForTesting
  Future<void> captureFrameForTest() async {
    _recording = true;
    await _capture();
  }

  void dispose() {
    stop();
    _moveTimer?.cancel();
  }

  Future<void> _tick() async {
    if (!_recording || _paused || _capturing) return;
    _capturing = true;
    try {
      await _capture();
    } catch (e) {
      NexusLog.debug('replay frame skipped: $e');
    } finally {
      _capturing = false;
    }
  }

  Future<void> _capture() async {
    final ctx = repaintBoundaryKey.currentContext;
    if (ctx == null) {
      if (!_warnedNoScope) {
        _warnedNoScope = true;
        NexusLog.warn('replay: NexusScope not mounted — nothing to capture. '
            'Wrap your app: runApp(NexusScope(child: MyApp())).');
      }
      return;
    }
    final boundary = ctx.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return;
    if (boundary.debugNeedsPaint) return; // mid-frame — try the next tick

    final ratio = _cfg.replayPixelRatio;
    final ui.Image shot = await boundary.toImage(pixelRatio: ratio);
    final int w = boundary.size.width.round();
    final int h = boundary.size.height.round();

    // Redact masked regions (explicit NexusMask + auto text fields) before the
    // pixels are ever encoded.
    final masks = <Rect>[
      if (!NexusMaskRegistry.instance.isEmpty) ...NexusMaskRegistry.instance.rectsIn(boundary),
      if (_cfg.replayMaskTextFields) ..._textFieldRects(boundary),
    ];
    final ui.Image finalImage = masks.isEmpty ? shot : await _redact(shot, masks, ratio);

    final ByteData? png = await finalImage.toByteData(format: ui.ImageByteFormat.png);
    if (!identical(finalImage, shot)) finalImage.dispose();
    shot.dispose();
    if (png == null) return;
    final bytes = png.buffer.asUint8List();

    // Skip unchanged frames (static screen) — a cheap sampled hash.
    final hash = _hash(bytes);
    if (hash == _lastHash) return;
    _lastHash = hash;

    _lastW = w;
    _lastH = h;
    final dataUri = 'data:image/png;base64,${base64Encode(bytes)}';
    if (!_sentFirst) {
      _sentFirst = true;
      _emit(Rrweb.meta(href: _currentHref, width: w, height: h));
      _emit(Rrweb.fullSnapshot(dataUri: dataUri, width: w, height: h));
      NexusLog.debug('replay: first frame captured (${w}x$h, ${bytes.length ~/ 1024}KB)');
    } else {
      _emit(Rrweb.frame(dataUri: dataUri));
    }
  }

  /// Bounds of every text-input render box (`RenderEditable` underlies
  /// TextField/TextFormField/CupertinoTextField/SelectableText), in the
  /// boundary's coordinate space — so typed content is auto-redacted.
  List<Rect> _textFieldRects(RenderObject boundary) {
    final out = <Rect>[];
    void visit(RenderObject node) {
      if (node is RenderEditable && node.attached && node.hasSize) {
        try {
          final topLeft = node.localToGlobal(Offset.zero, ancestor: boundary);
          out.add(topLeft & node.size);
        } catch (_) {/* off-tree / not laid out */}
      }
      node.visitChildren(visit);
    }

    boundary.visitChildren(visit);
    return out;
  }

  /// Paint solid blocks over mask rects (scaled to image pixels).
  Future<ui.Image> _redact(ui.Image src, List<Rect> masks, double ratio) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(src, Offset.zero, Paint());
    final paint = Paint()..color = const Color(0xFF1A1A1A);
    for (final r in masks) {
      canvas.drawRect(
        Rect.fromLTWH(r.left * ratio, r.top * ratio, r.width * ratio, r.height * ratio),
        paint,
      );
    }
    final picture = recorder.endRecording();
    final out = await picture.toImage(src.width, src.height);
    picture.dispose();
    return out;
  }

  // ---- pointer intake (from NexusScope's Listener) ----

  void onPointerDown(Offset p) {
    if (!_recording) return;
    _flushMoves();
    _emit(Rrweb.pointerDown(p.dx, p.dy));
  }

  void onPointerUp(Offset p) {
    if (!_recording) return;
    _flushMoves();
    _emit(Rrweb.pointerUp(p.dx, p.dy));
    _emit(Rrweb.click(p.dx, p.dy)); // so the inspector registers the tap
  }

  void onPointerMove(Offset p) {
    if (!_recording) return;
    _moveBuffer.add(Rrweb.position(p.dx, p.dy));
    _moveTimer ??= Timer(const Duration(milliseconds: 200), _flushMoves);
    if (_moveBuffer.length >= 10) _flushMoves();
  }

  void _flushMoves() {
    _moveTimer?.cancel();
    _moveTimer = null;
    if (_moveBuffer.isEmpty) return;
    final positions = List<Map<String, Object?>>.from(_moveBuffer);
    _moveBuffer.clear();
    _emit(Rrweb.pointerMove(positions));
  }

  // ---- console capture (Console tab) ----

  /// Tee `debugPrint` into the replay stream so the app's logs show in the
  /// player's Console tab, mirroring rrweb's console plugin. Our own `[Nexus]`
  /// lines are skipped to avoid a feedback loop.
  void _installConsoleCapture() {
    if (!_cfg.replayCaptureConsole || _originalDebugPrint != null) return;
    _originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      _originalDebugPrint?.call(message, wrapWidth: wrapWidth);
      if (message == null || !_recording || _paused) return;
      if (message.startsWith('[Nexus]')) return;
      _emit(Rrweb.consoleLog(_consoleLevel(message), message));
    };
  }

  void _restoreConsoleCapture() {
    if (_originalDebugPrint != null) {
      debugPrint = _originalDebugPrint!;
      _originalDebugPrint = null;
    }
  }

  static String _consoleLevel(String m) {
    final lower = m.toLowerCase();
    if (lower.contains('error') || lower.contains('exception')) return 'error';
    if (lower.contains('warn')) return 'warn';
    return 'log';
  }

  /// FNV-1a over a sampled subset of the PNG — enough to detect a changed frame
  /// without hashing megabytes each tick.
  static int _hash(Uint8List bytes) {
    var h = 0x811c9dc5;
    final step = bytes.length < 4096 ? 1 : bytes.length ~/ 4096;
    for (var i = 0; i < bytes.length; i += step) {
      h ^= bytes[i];
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h ^ bytes.length;
  }
}
