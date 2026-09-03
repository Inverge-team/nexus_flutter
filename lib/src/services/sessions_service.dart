import '../config.dart';
import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';

/// The sessions spine. `identify` names the end-user; `track` starts/refreshes
/// the journey session other services correlate into.
class NexusSessions {
  NexusSessions(this._http, this._id, this._cfg);

  final NexusHttp _http;
  final NexusIdentity _id;
  final NexusConfig _cfg;

  /// Identify the current end-user. All subsequent telemetry is attributed to it.
  Future<void> identify(
    String distinctId, {
    String? email,
    String? name,
    Map<String, Object?>? traits,
  }) async {
    _id.distinctId = distinctId;
    if (traits != null) _id.traits.addAll(traits);
    await _http.post('/partner/sessions/identify', {
      'distinctId': distinctId,
      'email': ?email,
      'name': ?name,
      'traits': ?traits,
    });
    await track();
  }

  /// Start/refresh the active session and return its server `sessionId`.
  Future<String?> track({Map<String, Object?>? context}) async {
    NexusLog.debug(
      'sessions.track — deviceKey=${_id.deviceKey}, sessionKey=${_id.sessionKey}'
      '${_id.distinctId != null ? ', distinctId=${_id.distinctId}' : ' (anonymous)'}',
    );
    final res = await _http.post('/partner/sessions/track', {
      if (_id.distinctId != null) 'distinctId': _id.distinctId,
      'deviceKey': _id.deviceKey,
      'sessionKey': _id.sessionKey,
      if (_cfg.appVersion != null) 'appVersion': _cfg.appVersion,
      ..._id.wireContext,
      ...?context,
    });
    final sessionId =
        res?['data']?['sessionId'] as String? ?? res?['sessionId'] as String?;
    if (sessionId != null) {
      NexusLog.info('session tracked → $sessionId');
    } else if (res == null) {
      NexusLog.warn(
        'session track failed — no session created (see the request error above)',
      );
    } else {
      NexusLog.warn('session track returned no sessionId — response: $res');
    }
    return sessionId;
  }

  /// Forget the current user (e.g. on logout) and start a fresh session.
  void reset() {
    _id.distinctId = null;
    _id.traits.clear();
    _id.rotateSession();
  }
}
