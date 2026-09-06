import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';
import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';

/// The device platform a push token belongs to.
enum PushPlatform { ios, android, web }

/// The delivery provider a push token targets.
enum PushProvider { fcm, apns, webpush }

/// Nexus Push. With `pushEnabled: true` this is fully turn-key — [start] runs at
/// init and handles permission, token acquisition, registration, refresh and
/// open-tracking for you. The manual methods ([registerToken]/[reportOpen]) stay
/// available for BYO-token setups (e.g. raw APNs or your own messaging plugin).
class NexusPush {
  NexusPush(this._http, this._id, this._cfg);

  final NexusHttp _http;
  final NexusIdentity _id;
  final NexusConfig _cfg;

  String? _token;
  StreamSubscription<String>? _refreshSub;
  StreamSubscription<RemoteMessage>? _openSub;

  /// The last token registered this launch.
  String? get token => _token;

  /// Turn-key enable: permission → token → register → refresh + open handlers.
  /// Called automatically when `pushEnabled` is set. Safe to call again; every
  /// failure is caught and logged so push can never break the app.
  Future<void> start() async {
    try {
      final platform = _detectPlatform();
      if (platform == null) {
        NexusLog.info('push: platform not supported for FCM — skipping');
        return;
      }
      if (!await _ensureFirebase(platform)) return;

      final messaging = FirebaseMessaging.instance;
      if (_cfg.pushAutoRequestPermission) {
        final settings = await messaging.requestPermission();
        NexusLog.debug('push: permission ${settings.authorizationStatus.name}');
      }

      final token = platform == PushPlatform.web
          ? await messaging.getToken(vapidKey: _cfg.pushWebVapidKey)
          : await messaging.getToken();
      if (token != null) {
        await registerToken(token, platform: platform, provider: PushProvider.fcm);
      }

      await _refreshSub?.cancel();
      _refreshSub = messaging.onTokenRefresh.listen(
        (t) => registerToken(t, platform: platform, provider: PushProvider.fcm),
      );

      // Attribute the open that launched / foregrounded the app.
      final initial = await messaging.getInitialMessage();
      if (initial != null) await reportOpen(initial.data);
      await _openSub?.cancel();
      _openSub = FirebaseMessaging.onMessageOpenedApp.listen((m) => reportOpen(m.data));

      NexusLog.info('push: enabled (${platform.name})');
    } catch (e) {
      NexusLog.warn('push: start failed — $e');
    }
  }

  /// Register (or refresh) this device's push token, correlated to the journey
  /// identity. Call this yourself only for BYO-token setups; `pushEnabled` does
  /// it automatically.
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

  /// Report a notification open. Reads `nexus_campaign_id` from the payload
  /// (Nexus stamps it on every campaign push) to power open-rate + A/B outcomes.
  /// With `pushEnabled` this is wired for you; call it manually only for BYO setups.
  Future<void> reportOpen(Map<String, dynamic> data) async {
    final campaignId = data['nexus_campaign_id'];
    if (campaignId is! String || _token == null) return;
    NexusLog.debug('push.reportOpen — campaign $campaignId');
    await _http.post('/partner/push/opened', {'campaignId': campaignId, 'token': _token});
  }

  /// Cancel the refresh/open listeners (called on Nexus dispose / re-init).
  Future<void> dispose() async {
    await _refreshSub?.cancel();
    await _openSub?.cancel();
  }

  Future<bool> _ensureFirebase(PushPlatform platform) async {
    if (Firebase.apps.isNotEmpty) return true;
    if (platform == PushPlatform.web) {
      NexusLog.warn('push: initialise Firebase yourself on web before enabling push');
      return false;
    }
    try {
      await Firebase.initializeApp(); // auto-configured on Android/iOS
      return true;
    } catch (e) {
      NexusLog.warn('push: Firebase.initializeApp failed — $e');
      return false;
    }
  }

  PushPlatform? _detectPlatform() {
    if (kIsWeb) return PushPlatform.web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return PushPlatform.android;
      case TargetPlatform.iOS:
        return PushPlatform.ios;
      default:
        return null;
    }
  }

  PushProvider _defaultProvider(PushPlatform p) =>
      p == PushPlatform.web ? PushProvider.webpush : PushProvider.fcm;

  String _mask(String t) => t.length <= 10 ? '***' : '${t.substring(0, 8)}…';
}
