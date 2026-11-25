import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

import '../app_identity.dart';
import '../billing_suspension.dart';
import '../config.dart';
import '../identity.dart';
import '../logging.dart';
import '../shield/shield_signing.dart';

typedef NexusEventHandler = void Function(dynamic data);

/// Realtime messaging over Socket.IO. Authenticates with the API key + the
/// current journey identity, so realtime connections join the same session.
class NexusRealtime {
  NexusRealtime(this._cfg, this._id);

  final NexusConfig _cfg;
  final NexusIdentity _id;
  io.Socket? _socket;
  final Set<String> _rooms = {};
  final Map<String, NexusEventHandler> _handlers = {};

  /// Reconnect scheduled for when a billing-suspension pause ends.
  Timer? _resumeTimer;

  String get _suspensionKey => NexusBillingSuspension.keyFor(_cfg.httpBase, _cfg.apiKey);

  bool get isConnected => _socket?.connected ?? false;

  /// Whether a socket exists (connected, or connecting/reconnecting) — i.e. the
  /// app wants realtime up, even if the link is momentarily down.
  bool get isActive => _socket != null;

  /// Open the connection (idempotent). Rooms are re-joined after a reconnect.
  void connect() {
    if (_socket != null) return;
    NexusLog.debug('realtime connecting → ${_cfg.socketBase}');
    final socket = io.io(
      _cfg.socketBase,
      io.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .disableAutoConnect()
          // A function, so every (re)connect builds a fresh payload — a Shield
          // proof is single-use (keys restricted to attested apps need one).
          .setAuthFn((cb) => _authPayload().then(cb, onError: (_) => cb(_basePayload())))
          .setExtraHeaders({'x-api-key': _cfg.apiKey})
          .build(),
    );
    // Register any handlers added before the socket existed; they persist across
    // this socket's reconnects.
    _handlers.forEach((event, handler) => socket.on(event, handler));
    socket.onConnect((_) {
      NexusLog.info('realtime connected (${socket.id})');
      for (final r in _rooms) {
        NexusLog.debug('realtime re-joining "$r" after (re)connect');
        socket.emitWithAck('room.join', {
          'name': r,
        }, ack: (dynamic res) => NexusLog.debug('realtime join "$r" ← $res'));
      }
    });
    socket.onDisconnect((_) => NexusLog.info('realtime disconnected'));
    socket.onConnectError((e) {
      if ('$e'.contains('api_key_restricted')) {
        _onRestricted(socket, e);
        return;
      }
      if (!'$e'.contains('billing_suspended')) {
        NexusLog.warn('realtime connect_error: $e');
        return;
      }
      // Paying the invoice is the only fix: stop socket.io's reconnect loop and
      // try once more when the pause ends (shared with every HTTP call).
      socket.disconnect();
      final data = e is Map ? e['data'] : null;
      final seconds = NexusBillingSuspension.instance
              .record(_suspensionKey, '/partner/rooms', 402, code: 'billing_suspended', details: data) ??
          NexusBillingSuspension.defaultSeconds;
      NexusLog.warn('realtime: API access is suspended for an overdue invoice — retrying in ${seconds}s');
      _resumeAfter(socket, Duration(seconds: seconds));
    });
    socket.onConnect((_) => NexusBillingSuspension.instance.record(_suspensionKey, '/partner/rooms', 200));
    _socket = socket;
    final wait = NexusBillingSuspension.instance.remaining(_suspensionKey, '/partner/rooms');
    if (wait > Duration.zero) {
      _resumeAfter(socket, wait);
    } else {
      socket.connect();
    }
  }

  Map<String, dynamic> _basePayload() => {
        'key': _cfg.apiKey,
        if (_id.distinctId != null) 'distinctId': _id.distinctId,
        'sessionKey': _id.sessionKey,
        'deviceKey': _id.deviceKey,
        'os': _id.deviceContext['osType'],
        'osVersion': _id.deviceContext['osVersion'],
        ...NexusAppIdentity.socketAuth(),
      };

  bool _refreshShield = false;
  DateTime? _restrictedRetryAt;

  Future<Map<String, dynamic>> _authPayload() async {
    final payload = _basePayload();
    if (NexusShieldSigning.active) {
      final force = _refreshShield;
      _refreshShield = false;
      payload.addAll(await NexusShieldSigning.socketAuth(_cfg.socketBase, forceRefresh: force));
    }
    return payload;
  }

  /// The key only accepts attested apps: turn Shield signing on and reconnect
  /// (at most every 30 s, so a key that rejects this app can't spin).
  void _onRestricted(io.Socket socket, dynamic e) {
    socket.disconnect();
    final data = e is Map ? e['data'] : null;
    final reason = data is Map ? data['reason'] as String? : null;
    if (!_cfg.shieldEnabled || (reason != 'shield_token_required' && reason != 'shield_token_invalid')) {
      NexusLog.error('realtime: this API key does not accept this app (${reason ?? 'api_key_restricted'})'
          '${_cfg.shieldEnabled ? '' : ' — set NexusConfig.shieldEnabled: true'}');
      return;
    }
    final now = DateTime.now();
    final wait = _restrictedRetryAt != null && now.isBefore(_restrictedRetryAt!) ? const Duration(seconds: 30) : Duration.zero;
    _restrictedRetryAt = now.add(const Duration(seconds: 30));
    _refreshShield = reason == 'shield_token_invalid';
    unawaited(NexusShieldSigning.activate());
    _resumeAfter(socket, wait);
  }

  void _resumeAfter(io.Socket socket, Duration wait) {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(wait, () {
      _resumeTimer = null;
      if (identical(_socket, socket)) socket.connect();
    });
  }

  /// Join a room (first/created on the server). Re-joined automatically on
  /// reconnect. Returns the server's acknowledgement (`{ ok, room }`).
  Future<dynamic> join(String room) {
    _rooms.add(room);
    NexusLog.info('realtime join "$room"');
    return _ackEmit('room.join', {'name': room}, label: 'join "$room"');
  }

  /// Leave a room. Returns the server's acknowledgement (`{ ok }`).
  Future<dynamic> leave(String room) {
    _rooms.remove(room);
    NexusLog.info('realtime leave "$room"');
    return _ackEmit('room.leave', {'name': room}, label: 'leave "$room"');
  }

  /// Emit one or more named events to a room with a payload. Returns the
  /// server's acknowledgement (`{ ok, room, recipients, related }` or
  /// `{ error }`), which is also logged.
  Future<dynamic> emit(String room, dynamic event, [Object? payload]) {
    final events = event is List ? event : [event];
    NexusLog.debug('realtime emit $events → "$room"');
    return _ackEmit('room.emit', {
      'name': room,
      'event': events,
      'payload': payload,
    }, label: 'emit $events → "$room"');
  }

  /// Emit with an acknowledgement, logging the response. Resolves null (and
  /// warns) when not connected.
  Future<dynamic> _ackEmit(
    String message,
    Map<String, Object?> body, {
    required String label,
  }) {
    final socket = _socket;
    if (socket == null) {
      NexusLog.warn('realtime $label dropped — not connected');
      return Future.value(null);
    }
    final completer = Completer<dynamic>();
    socket.emitWithAck(
      message,
      body,
      ack: (dynamic res) {
        final isError = res is Map && res['error'] != null;
        if (isError) {
          NexusLog.warn('realtime $label ← $res');
        } else {
          NexusLog.debug('realtime $label ← $res');
        }
        if (!completer.isCompleted) completer.complete(res);
      },
    );
    return completer.future;
  }

  /// Listen for a server event. Persisted, so it survives (re)connects and works
  /// even if called before the socket is open.
  void on(String event, NexusEventHandler handler) {
    _handlers[event] = handler;
    _socket?.off(event); // one handler per event, matching [_handlers]
    _socket?.on(event, handler);
  }

  /// Stop listening for a server event.
  void off(String event) {
    _handlers.remove(event);
    _socket?.off(event);
  }

  void disconnect() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _socket?.dispose();
    _socket = null;
  }
}
