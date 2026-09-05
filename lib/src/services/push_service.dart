import '../config.dart';
import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';

/// The device platform a push token belongs to.
enum PushPlatform { ios, android, web }

/// The delivery provider a push token targets.
enum PushProvider { fcm, apns, webpush }

/// Nexus Push — register this device's push token so campaigns and automations
/// can reach it, and report opens so the console shows delivery outcomes.
///
/// Nexus does not itself talk to FCM/APNs on the client; obtain the token with
/// your push plugin (e.g. `firebase_messaging`) and hand it to
/// [registerToken]. Feed notification payloads to [reportOpen] to attribute opens.
class NexusPush {
  NexusPush(this._http, this._id, this._cfg);

  final NexusHttp _http;
  final NexusIdentity _id;
  final NexusConfig _cfg;

  String? _token;

  /// The last token registered this launch (for [unregister] / [reportOpen]).
  String? get token => _token;

  /// Register (or refresh) this device's push token. Correlates to the current
  /// journey identity (distinctId/deviceKey), so targeting by user works.
  ///
  /// [provider] defaults to `fcm` on iOS/Android (the common Firebase setup) and
  /// `webpush` on web — pass `PushProvider.apns` if you register raw APNs tokens.
  Future<void> registerToken(
    String token, {
    required PushPlatform platform,
    PushProvider? provider,
    String? lang,
  }) async {
    _token = token;
    final resolved = provider ?? _defaultProvider(platform);
    NexusLog.debug('push.registerToken — ${platform.name}/${resolved.name} ${_mask(token)}');
    await _http.post('/partner/push/register', {
      'token': token,
      'platform': platform.name,
      'provider': resolved.name,
      'distinctId': ?_id.distinctId,
      'deviceKey': _id.deviceKey,
      'appVersion': ?_cfg.appVersion,
      'lang': ?lang,
      ..._id.wireContext,
    });
  }

  /// Stop delivering to a token (call on logout/uninstall). Defaults to the last
  /// registered token.
  Future<void> unregister([String? token]) async {
    final t = token ?? _token;
    if (t == null) return;
    await _http.post('/partner/push/unregister', {'token': t});
    if (t == _token) _token = null;
  }

  /// Report that a notification was opened. Pass the notification's `data` map —
  /// if it carries `nexus_campaign_id` (Nexus stamps this on every campaign push)
  /// the open is attributed, powering open-rate and A/B outcomes in the console.
  Future<void> reportOpen(Map<String, dynamic> data) async {
    final campaignId = data['nexus_campaign_id'];
    if (campaignId is! String || _token == null) return;
    NexusLog.debug('push.reportOpen — campaign $campaignId');
    await _http.post('/partner/push/opened', {'campaignId': campaignId, 'token': _token});
  }

  PushProvider _defaultProvider(PushPlatform p) =>
      p == PushPlatform.web ? PushProvider.webpush : PushProvider.fcm;

  String _mask(String t) => t.length <= 10 ? '***' : '${t.substring(0, 8)}…';
}
