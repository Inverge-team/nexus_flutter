import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../nexus_platform_interface.dart';
import '../background_dispatch.dart';
import '../config.dart';
import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';
import 'live_activity_service.dart';

/// A notification open (or action-button tap) surfaced to the app.
class NexusPushOpen {
  const NexusPushOpen({required this.data, this.campaignId, this.actionId, this.actionUrl});

  /// The full data payload of the notification.
  final Map<String, dynamic> data;

  /// The Nexus campaign id, when the open was a campaign push.
  final String? campaignId;

  /// The id of the action button tapped, or null for a tap on the body.
  final String? actionId;

  /// The URL attached to the tapped action button, if any (open it yourself).
  final String? actionUrl;
}

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
  String? _lang;
  final Map<String, String> _tags = {};
  bool _tagsTouched = false;
  PushPlatform? _lastPlatform;
  PushProvider? _lastProvider;
  StreamSubscription<String>? _refreshSub;
  StreamSubscription<RemoteMessage>? _openSub;
  StreamSubscription<RemoteMessage>? _fgSub;

  /// Called when a notification (or one of its action buttons) is opened. Set
  /// this to route the user, or to handle an action button's `actionUrl`.
  void Function(NexusPushOpen open)? onOpened;

  /// The last token registered this launch.
  String? get token => _token;

  /// The language notifications are localized to for this device (or null).
  String? get language => _lang;

  /// Set the user's app language so campaigns are delivered localized to it
  /// (e.g. `setLanguage('en')` / `setLanguage('ar')`). Call it at startup with
  /// the app's current locale, and again whenever the user changes it. The code
  /// is attached to the device token; a campaign with content for that language
  /// is sent in it, otherwise the campaign's default language is used.
  ///
  /// Safe to call before or after push is enabled — if a token is already
  /// registered it re-registers immediately; otherwise the language is applied
  /// on the next registration.
  Future<void> setLanguage(String lang) async {
    final code = lang.trim();
    if (code.isEmpty || code == _lang) return;
    _lang = code;
    final token = _token;
    final platform = _lastPlatform;
    if (token != null && platform != null) {
      await registerToken(token, platform: platform, provider: _lastProvider);
    }
  }

  /// The subscriber tags currently set on this device.
  Map<String, String> get tags => Map.unmodifiable(_tags);

  /// Tag this subscriber with a key/value so you can target them in segments —
  /// e.g. `setTag('role', 'client')`, `setTag('username', 'ehs4nnn')`. Build
  /// tag-condition segments in the console (Push → Segments → Tag is …).
  ///
  /// Safe before or after push is enabled: if a token is already registered the
  /// tags sync immediately, otherwise they're attached on the next registration.
  Future<void> setTag(String key, String value) => setTags({key: value});

  /// Set several tags at once (merged into the existing tags).
  Future<void> setTags(Map<String, String> tags) async {
    if (tags.isEmpty) return;
    tags.forEach((k, v) {
      final key = k.trim();
      if (key.isNotEmpty) _tags[key] = v;
    });
    _tagsTouched = true;
    await _syncTags();
  }

  /// Remove a previously set tag.
  Future<void> removeTag(String key) async {
    if (_tags.remove(key.trim()) == null) return;
    _tagsTouched = true;
    await _syncTags();
  }

  /// Clear all tags from this subscriber.
  Future<void> clearTags() async {
    if (_tags.isEmpty && _tagsTouched) return;
    _tags.clear();
    _tagsTouched = true;
    await _syncTags();
  }

  Future<void> _syncTags() async {
    final token = _token;
    final platform = _lastPlatform;
    if (token != null && platform != null) {
      await registerToken(token, platform: platform, provider: _lastProvider);
    }
  }

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

      // FCM does not draw a notification while the app is foregrounded — show it
      // ourselves so notifications appear whether the app is open or not.
      if (_cfg.pushForegroundDisplay) await _setupForegroundDisplay(platform, messaging);

      // Android: campaigns arrive as data messages so the SDK renders every
      // notification natively (foreground AND background/killed) with full
      // options + action buttons. Register the background renderer.
      if (platform == PushPlatform.android && _cfg.pushForegroundDisplay) {
        // Single shared background handler — see ensureNexusBackgroundHandler.
        // (Registering nexusPushBackgroundHandler directly would clobber Voice.)
        ensureNexusBackgroundHandler();
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
    _lastPlatform = platform;
    _lastProvider = resolved;
    final effectiveLang = lang ?? _lang;
    NexusLog.debug('push.registerToken — ${platform.name}/${resolved.name} ${_mask(token)}');
    await _http.post('/partner/push/register', {
      'token': token,
      'platform': platform.name,
      'provider': resolved.name,
      'distinctId': ?_id.distinctId,
      'deviceKey': _id.deviceKey,
      'appVersion': ?_cfg.appVersion,
      'lang': ?effectiveLang,
      if (_tagsTouched) 'tags': _tags,
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
    // Surface the open (incl. action button + url) to the app.
    final campaignId = data['nexus_campaign_id'];
    onOpened?.call(NexusPushOpen(
      data: data,
      campaignId: campaignId is String ? campaignId : null,
      actionId: data['nexus_action_id']?.toString(),
      actionUrl: data['nexus_action_url']?.toString(),
    ));
    if (campaignId is! String || _token == null) return;
    NexusLog.debug('push.reportOpen — campaign $campaignId');
    await _http.post('/partner/push/opened', {'campaignId': campaignId, 'token': _token});
  }

  /// Cancel the refresh/open/foreground listeners (called on Nexus dispose / re-init).
  Future<void> dispose() async {
    await _refreshSub?.cancel();
    await _openSub?.cancel();
    await _fgSub?.cancel();
  }

  /// Make foreground pushes visible. iOS presents the banner natively via the
  /// Firebase SDK; Android never does, so we post the notification through our
  /// own native plugin (no third-party libraries) and attribute taps back
  /// through [reportOpen], exactly like a background open.
  Future<void> _setupForegroundDisplay(PushPlatform platform, FirebaseMessaging messaging) async {
    if (platform == PushPlatform.ios) {
      // Ask iOS to show the banner/sound/badge itself while the app is open.
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      return;
    }
    if (platform != PushPlatform.android) return;

    // Taps on our native notification come back here → attribute the open.
    NexusPlatform.instance.onNotificationTap((data) => unawaited(reportOpen(data)));

    await _fgSub?.cancel();
    _fgSub = FirebaseMessaging.onMessage.listen(_showForeground);
  }

  /// Render one foreground message as a native notification (Android).
  Future<void> _showForeground(RemoteMessage m) => renderNexusAndroidNotification(
        m,
        channelId: _cfg.pushAndroidChannelId,
        channelName: _cfg.pushAndroidChannelName,
      );

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

/// Background FCM handler (Android). Runs in a separate isolate when a data
/// message arrives with the app backgrounded or killed, and renders the
/// notification natively — so action buttons and rich options work in every
/// app state. Registered by [NexusPush.start].
@pragma('vm:entry-point')
Future<void> nexusPushBackgroundHandler(RemoteMessage message) async {
  await renderNexusAndroidNotification(message);
}

/// Render an Android notification from an FCM [message] using the native plugin,
/// honouring the campaign's rich options (buttons, large/big/small icon,
/// lockscreen visibility, accent colour) carried in `nexus_options`. Shared by
/// the foreground listener and the background isolate handler.
Future<void> renderNexusAndroidNotification(
  RemoteMessage message, {
  String channelId = 'nexus_default',
  String channelName = 'Notifications',
}) async {
  final n = message.notification;
  final data = message.data;
  // Live Activity data message → drive the live ongoing notification instead.
  final la = parseLiveActivityPayload(data['nexus_live_activity']);
  if (la != null) {
    await renderNexusLiveActivity(la);
    return;
  }
  final title = (data['nexus_title'] ?? data['title'] ?? n?.title) as String?;
  final body = (data['nexus_body'] ?? data['body'] ?? n?.body) as String?;
  if (title == null && body == null) return; // silent data message — nothing to show
  final opt = _parseOptions(data['nexus_options']);
  await NexusPlatform.instance.showNotification(
    id: message.hashCode,
    title: title,
    body: body,
    channelId: (opt['androidChannelId'] as String?) ?? n?.android?.channelId ?? channelId,
    channelName: channelName,
    payload: jsonEncode(data),
    largeIcon: opt['androidLargeIcon'] as String?,
    bigPicture: (opt['androidBigPicture'] as String?) ?? n?.android?.imageUrl,
    smallIcon: opt['androidSmallIcon'] as String?,
    visibility: opt['androidVisibility'] as String?,
    accentColor: opt['androidAccentColor'] as String?,
    buttons: _parseButtons(opt['buttons']),
  );
}

Map<String, dynamic> _parseOptions(Object? raw) {
  if (raw is String && raw.isNotEmpty) {
    try {
      final d = jsonDecode(raw);
      if (d is Map) return d.cast<String, dynamic>();
    } catch (_) {}
  }
  if (raw is Map) return raw.cast<String, dynamic>();
  return const {};
}

List<Map<String, String?>>? _parseButtons(Object? raw) {
  if (raw is! List) return null;
  final out = <Map<String, String?>>[];
  for (final b in raw) {
    if (b is Map) {
      final id = b['id']?.toString();
      final text = b['text']?.toString();
      if (id == null || text == null) continue;
      out.add({'id': id, 'text': text, 'icon': b['icon']?.toString(), 'url': b['url']?.toString()});
    }
  }
  return out.isEmpty ? null : out;
}
