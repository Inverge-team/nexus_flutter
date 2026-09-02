import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config.dart';
import '../identity.dart';
import '../logging.dart';

typedef NexusEventHandler = void Function(dynamic data);

/// Realtime messaging over Socket.IO. Authenticates with the API key + the
/// current journey identity, so realtime connections join the same session.
class NexusRealtime {
  NexusRealtime(this._cfg, this._id);

  final NexusConfig _cfg;
  final NexusIdentity _id;
  io.Socket? _socket;
  final Set<String> _rooms = {};

  bool get isConnected => _socket?.connected ?? false;

  /// Open the connection (idempotent). Rooms are re-joined after a reconnect.
  void connect() {
    if (_socket != null) return;
    NexusLog.debug('realtime connecting → ${_cfg.socketBase}');
    final socket = io.io(
      _cfg.socketBase,
      io.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .disableAutoConnect()
          .setAuth({
            'key': _cfg.apiKey,
            if (_id.distinctId != null) 'distinctId': _id.distinctId,
            'sessionKey': _id.sessionKey,
            'deviceKey': _id.deviceKey,
            'os': _id.deviceContext['osType'],
            'osVersion': _id.deviceContext['osVersion'],
          })
          .setExtraHeaders({'x-api-key': _cfg.apiKey})
          .build(),
    );
    socket.onConnect((_) {
      NexusLog.info('realtime connected (${socket.id})');
      for (final r in _rooms) {
        NexusLog.debug('realtime re-joining "$r" after (re)connect');
        socket.emitWithAck('room.join', {'room': r},
            ack: (dynamic res) => NexusLog.debug('realtime join "$r" ← $res'));
      }
    });
    socket.onDisconnect((_) => NexusLog.info('realtime disconnected'));
    socket.onConnectError((e) => NexusLog.warn('realtime connect_error: $e'));
    _socket = socket;
    socket.connect();
  }

  /// Join a room (first/created on the server). Re-joined automatically on
  /// reconnect. Returns the server's acknowledgement (`{ ok, room, related }`).
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
    return _ackEmit(
      'room.emit',
      {'room': room, 'events': events, 'payload': payload},
      label: 'emit $events → "$room"',
    );
  }

  /// Emit with an acknowledgement, logging the response. Resolves null (and
  /// warns) when not connected.
  Future<dynamic> _ackEmit(String message, Map<String, Object?> body, {required String label}) {
    final socket = _socket;
    if (socket == null) {
      NexusLog.warn('realtime $label dropped — not connected');
      return Future.value(null);
    }
    final completer = Completer<dynamic>();
    socket.emitWithAck(message, body, ack: (dynamic res) {
      final isError = res is Map && res['error'] != null;
      if (isError) {
        NexusLog.warn('realtime $label ← $res');
      } else {
        NexusLog.debug('realtime $label ← $res');
      }
      if (!completer.isCompleted) completer.complete(res);
    });
    return completer.future;
  }

  /// Listen for a server event.
  void on(String event, NexusEventHandler handler) => _socket?.on(event, handler);

  /// Stop listening for a server event.
  void off(String event) => _socket?.off(event);

  void disconnect() {
    _socket?.dispose();
    _socket = null;
  }
}
