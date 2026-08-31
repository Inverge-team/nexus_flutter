import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config.dart';
import '../identity.dart';

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
      _log('connected ${socket.id}');
      for (final r in _rooms) {
        socket.emit('room.join', {'room': r});
      }
    });
    socket.onDisconnect((_) => _log('disconnected'));
    socket.onConnectError((e) => _log('connect_error $e'));
    _socket = socket;
    socket.connect();
  }

  /// Join a room (first/created on the server). Re-joined automatically on reconnect.
  void join(String room) {
    _rooms.add(room);
    _socket?.emit('room.join', {'room': room});
  }

  /// Leave a room.
  void leave(String room) {
    _rooms.remove(room);
    _socket?.emit('room.leave', {'room': room});
  }

  /// Emit one or more named events to a room with a payload.
  void emit(String room, dynamic event, [Object? payload]) {
    _socket?.emit('room.emit', {
      'room': room,
      'events': event is List ? event : [event],
      'payload': payload,
    });
  }

  /// Listen for a server event.
  void on(String event, NexusEventHandler handler) => _socket?.on(event, handler);

  /// Stop listening for a server event.
  void off(String event) => _socket?.off(event);

  void disconnect() {
    _socket?.dispose();
    _socket = null;
  }

  void _log(String msg) {
    if (_cfg.logging) debugPrint('[Nexus.realtime] $msg');
  }
}
