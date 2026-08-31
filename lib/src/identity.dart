import 'dart:math';

/// Shared journey identity for the whole SDK. Every service stamps these onto
/// its telemetry so the backend correlates realtime, events, errors, logs and
/// replay into one session — the umbrella's core value.
class NexusIdentity {
  NexusIdentity() : sessionKey = _randomId('sess'), deviceKey = _randomId('dev');

  /// The end-user id, set via [Nexus.identify]. Null until identified.
  String? distinctId;

  /// A stable-per-launch session id. Sent as `sessionKey` so the backend groups
  /// activity within a bounded session.
  String sessionKey;

  /// A per-install device id (regenerated per launch here; native SDKs persist it).
  String deviceKey;

  /// Person properties supplied at identify time (email/name/traits).
  final Map<String, Object?> traits = {};

  /// Best-effort device/platform context filled in from the native layer.
  Map<String, Object?> deviceContext = {};

  /// Start a fresh session (e.g. after a long background gap).
  void rotateSession() => sessionKey = _randomId('sess');

  static String _randomId(String prefix) {
    final r = Random.secure();
    final bytes = List<int>.generate(9, (_) => r.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${prefix}_$hex';
  }
}
