import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'http_client.dart';
import 'logging.dart';

class _OutboxItem {
  _OutboxItem({
    required this.id,
    required this.path,
    required this.body,
    this.attempts = 0,
    required this.createdAt,
  });

  final String id;
  final String path;
  final Map<String, Object?> body;
  int attempts;
  final int createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'path': path,
    'body': body,
    'attempts': attempts,
    'createdAt': createdAt,
  };

  static _OutboxItem fromJson(Map<String, dynamic> j) => _OutboxItem(
    id: j['id'] as String,
    path: j['path'] as String,
    body: Map<String, Object?>.from(j['body'] as Map),
    attempts: (j['attempts'] as num?)?.toInt() ?? 0,
    createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
  );
}

/// A durable, at-least-once outbox for fire-and-forget telemetry. Requests are
/// persisted (so they survive restarts), delivered when the network is up, and
/// retried with exponential backoff. Delivery stops on the first failure (likely
/// offline) and resumes later; individual items are dropped after [maxAttempts].
class NexusOutbox {
  NexusOutbox(
    this._http,
    NexusConfig config, {
    this.maxItems = 500,
    this.maxAttempts = 8,
    this.retryInterval = const Duration(seconds: 30),
  }) : assert(config.maxBatch > 0);

  final NexusHttp _http;
  final int maxItems;
  final int maxAttempts;
  final Duration retryInterval;

  static const _storageKey = 'nexus_outbox_v1';

  final List<_OutboxItem> _items = [];
  SharedPreferences? _prefs;
  Timer? _retryTimer;
  Timer? _backoffTimer;
  bool _draining = false;
  int _backoff = 0;

  int get pending => _items.length;

  /// Load persisted items and start the periodic retry timer.
  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final raw = _prefs?.getString(_storageKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _items.addAll(
          list.map((e) => _OutboxItem.fromJson(e as Map<String, dynamic>)),
        );
      }
    } catch (_) {
      /* start empty on any corruption */
    }
    _retryTimer = Timer.periodic(retryInterval, (_) => drain());
    if (_items.isNotEmpty) unawaited(drain());
  }

  /// Enqueue a telemetry request for durable, retried delivery.
  void enqueue(String path, Map<String, Object?> body) {
    _items.add(
      _OutboxItem(
        id: _genId(),
        path: path,
        body: body,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    while (_items.length > maxItems) {
      _items.removeAt(0); // drop oldest under sustained offline pressure
    }
    NexusLog.debug('outbox queued $path ($pending pending)');
    _persist();
    unawaited(drain());
  }

  /// Attempt to deliver queued items in order. Idempotent + reentrancy-guarded.
  Future<void> drain() async {
    if (_draining || _items.isEmpty) return;
    _draining = true;
    try {
      var failed = false;
      for (final item in List<_OutboxItem>.from(_items)) {
        final ok = await _http.post(item.path, item.body) != null;
        if (ok) {
          _items.remove(item);
        } else {
          item.attempts++;
          if (item.attempts >= maxAttempts) {
            _items.remove(item); // give up on a poison item
            NexusLog.warn(
              'outbox dropped ${item.path} after $maxAttempts attempts ($pending pending)',
            );
          } else {
            failed = true;
            break; // likely offline — stop and back off
          }
        }
      }
      _persist();
      if (failed) {
        _backoff = min(_backoff + 1, 6);
        _backoffTimer?.cancel();
        _backoffTimer = Timer(
          Duration(seconds: 1 << _backoff),
          () => drain(),
        ); // 2,4,…,64s
      } else {
        _backoff = 0;
      }
    } finally {
      _draining = false;
    }
  }

  void dispose() {
    _retryTimer?.cancel();
    _backoffTimer?.cancel();
    _persist();
  }

  void _persist() {
    try {
      _prefs?.setString(
        _storageKey,
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      /* non-fatal */
    }
  }

  static String _genId() {
    final r = Random();
    return '${DateTime.now().microsecondsSinceEpoch}_${r.nextInt(1 << 20)}';
  }
}
