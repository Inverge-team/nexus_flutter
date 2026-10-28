import 'dart:async';
import 'dart:convert';

import 'package:socket_io_client/socket_io_client.dart' as io;

import 'client.dart';

/// Handlers for one live subscription. [onSnapshot] gets the subscribe ack and
/// runs again after every reconnect — reset state from it.
class LiveHandlers {
  LiveHandlers({this.onSnapshot, this.onChanges, this.onDoc, this.onAggregate, this.onError});
  final void Function(Map<String, Object?> ack)? onSnapshot;
  final void Function(List<Map<String, Object?>> changes, bool hasMore)? onChanges;
  final void Function(Map<String, Object?>? doc)? onDoc;
  final void Function(Object? result)? onAggregate;
  final void Function(String code, String message)? onError;
}

enum LiveStatus { connecting, live, offline, stopped }

/// One Socket.IO connection to `/docstore` for all of a client's live queries,
/// documents, aggregates and sync pokes. Re-subscribes after reconnects,
/// refreshes the end-user token before it expires, and stops (instead of
/// retrying forever) on `billing_suspended`.
class DocStoreLive {
  DocStoreLive(this._opts);

  final DocStoreOptions _opts;
  io.Socket? _socket;
  final _subs = <String, ({Map<String, Object?> payload, LiveHandlers handlers})>{};
  final _pokes = <int, ({List<String> collections, void Function() fn})>{};
  final _status = StreamController<LiveStatus>.broadcast();
  Timer? _refresh;
  int _seq = 0;
  LiveStatus status = LiveStatus.connecting;

  Stream<LiveStatus> get statusChanges => _status.stream;

  void Function() subscribe(Map<String, Object?> payload, LiveHandlers handlers) {
    final subId = 's${++_seq}';
    _subs[subId] = (payload: payload, handlers: handlers);
    final s = _ensure();
    if (s.connected) _send(s, subId);
    return () {
      _subs.remove(subId);
      if (_socket?.connected ?? false) _socket!.emit('unsubscribe', {'subId': subId});
    };
  }

  void Function() watch(List<String> collections, void Function() fn) {
    final id = ++_seq;
    _pokes[id] = (collections: collections, fn: fn);
    _ensure();
    _sendWatch();
    return () {
      _pokes.remove(id);
      _sendWatch();
    };
  }

  void close() {
    _refresh?.cancel();
    _socket?.dispose();
    _socket = null;
    _subs.clear();
    _pokes.clear();
    _setStatus(LiveStatus.stopped);
  }

  io.Socket _ensure() {
    final existing = _socket;
    if (existing != null) return existing;
    final base = (_opts.realtimeUrl ?? _opts.baseUrl).replaceAll(RegExp(r'/+$'), '');
    final socket = io.io(
      '$base/docstore',
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableForceNew()
          // A function: evaluated on every (re)connect, so it always sends a current token.
          .setAuthFn((cb) => _authPayload(false).then(cb, onError: (_) => cb({'key': _opts.apiKey})))
          .build(),
    );
    socket.onConnect((_) {
      _setStatus(LiveStatus.live);
      _scheduleRefresh();
      for (final id in _subs.keys.toList()) {
        _send(socket, id);
      }
      _sendWatch();
    });
    socket.onDisconnect((_) {
      if (status != LiveStatus.stopped) _setStatus(LiveStatus.connecting);
    });
    socket.onConnectError((err) {
      if ('$err'.contains('billing_suspended')) {
        socket.disconnect();
        _setStatus(LiveStatus.stopped);
        for (final s in _subs.values) {
          s.handlers.onError?.call('billing_suspended', 'Nexus access is suspended for unpaid invoices');
        }
        return;
      }
      _setStatus(LiveStatus.offline);
    });
    socket.on('changes', (m) {
      final map = _map(m);
      final h = _subs[map['subId']]?.handlers;
      h?.onChanges?.call(((map['changes'] as List?) ?? const []).map(_map).toList(), map['hasMore'] == true);
    });
    socket.on('doc', (m) {
      final map = _map(m);
      _subs[map['subId']]?.handlers.onDoc?.call(map['doc'] == null ? null : _map(map['doc']));
    });
    socket.on('aggregate', (m) {
      final map = _map(m);
      _subs[map['subId']]?.handlers.onAggregate?.call(map['result']);
    });
    socket.on('sync.poke', (m) {
      final changed = ((_map(m)['collections'] as List?) ?? const []).cast<String>();
      for (final w in _pokes.values) {
        if (changed.any(w.collections.contains)) w.fn();
      }
    });
    socket.on('db.error', (m) {
      final map = _map(m);
      if (map['code'] == 'token_expired') {
        // Subscriptions were dropped server-side: re-auth, reconnect re-sends them.
        _reauth(true).whenComplete(() {
          socket.disconnect();
          socket.connect();
        });
        return;
      }
      final subId = map['subId'];
      if (subId != null) _subs[subId]?.handlers.onError?.call('${map['code']}', '${map['message']}');
    });
    _socket = socket;
    socket.connect();
    return socket;
  }

  Future<Map<String, Object?>> _authPayload(bool force) async {
    if (_opts.serviceKey != null) return {'key': _opts.apiKey, 'serviceKey': _opts.serviceKey};
    final t = _opts.getToken == null ? null : await _opts.getToken!(forceRefresh: force);
    return {'key': _opts.apiKey, 'token': ?t};
  }

  Future<void> _send(io.Socket socket, String subId) async {
    final sub = _subs[subId];
    if (sub == null) return;
    final ack = _map(await socket.emitWithAckAsync('subscribe', {...sub.payload, 'subId': subId}));
    if (!_subs.containsKey(subId)) return;
    if (ack['error'] != null) {
      sub.handlers.onError?.call('${ack['error']}', '${ack['message'] ?? ack['error']}');
    } else {
      sub.handlers.onSnapshot?.call(ack);
    }
  }

  void _sendWatch() {
    final s = _socket;
    if (s == null || !s.connected) return;
    final all = <String>{for (final w in _pokes.values) ...w.collections};
    s.emit('sync.watch', {'collections': all.toList()});
  }

  Future<void> _reauth(bool force) async {
    final s = _socket;
    if (_opts.getToken == null || s == null || !s.connected) return;
    final t = await _opts.getToken!(forceRefresh: force);
    if (t != null) await s.emitWithAckAsync('auth', {'token': t});
  }

  /// Present a fresh end-user token ~60 s before the current one expires.
  void _scheduleRefresh() {
    _refresh?.cancel();
    if (_opts.getToken == null || _opts.serviceKey != null) return;
    Future.value(_opts.getToken!(forceRefresh: false)).then((t) {
      final exp = _jwtExp(t);
      if (exp == null) return;
      final wait = exp.difference(DateTime.now()) - const Duration(seconds: 60);
      _refresh = Timer(wait < const Duration(seconds: 5) ? const Duration(seconds: 5) : wait, () => _reauth(true).whenComplete(_scheduleRefresh));
    });
  }

  void _setStatus(LiveStatus s) {
    status = s;
    if (!_status.isClosed) _status.add(s);
  }
}

Map<String, Object?> _map(Object? v) => v is Map ? v.cast<String, Object?>() : <String, Object?>{};

DateTime? _jwtExp(String? token) {
  if (token == null) return null;
  try {
    final part = token.split('.')[1];
    final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(part)))) as Map;
    final exp = json['exp'];
    return exp is num ? DateTime.fromMillisecondsSinceEpoch((exp * 1000).toInt()) : null;
  } catch (_) {
    return null;
  }
}
