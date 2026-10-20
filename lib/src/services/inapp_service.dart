import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../http_client.dart';
import '../identity.dart';
import '../inapp/inapp_models.dart';
import '../logging.dart';
import 'realtime_service.dart';

/// In-app messages (OneSignal-style). Fetches the messages meant for this user —
/// the server applies the audience, assigns the A/B variant and fills in
/// `{{variables}}` — then evaluates triggers (session start / custom event) and
/// frequency caps locally, requests display, and reports impressions/clicks.
/// Rendering is done by `NexusInAppOverlay` (default UI) or your own widget
/// driven by [current].
class NexusInApp {
  NexusInApp(this._http, this._id, this._cfg);

  final NexusHttp _http;
  final NexusIdentity _id;
  final NexusConfig _cfg;

  /// The message currently requested to display (null when none). The overlay
  /// listens to this.
  final ValueNotifier<NexusInAppMessage?> current = ValueNotifier<NexusInAppMessage?>(null);

  /// Called when a user taps a button (handle `url` / `event` actions yourself,
  /// e.g. navigate or `launchUrl`). Event-action buttons are also auto-tracked.
  void Function(NexusInAppAction action)? onAction;

  List<NexusInAppMessage> _active = const [];
  final Map<String, Object?> _properties = {};
  NexusRealtime? _realtime;
  String? _testRoom;

  /// Properties for audience targeting and personalisation, on top of the
  /// identify traits: `setProperties({'plan': 'pro', 'coupon': 'SARA20'})`
  /// matches the console's `plan` conditions and fills `{{coupon}}`. Kept for
  /// this launch; pass `refetch: false` to wait for the next fetch.
  Future<void> setProperties(Map<String, Object?> properties, {bool refetch = true}) async {
    _properties.addAll(properties);
    if (refetch) await fetch();
  }

  /// Remove properties set with [setProperties].
  void clearProperties([Iterable<String>? keys]) {
    if (keys == null) {
      _properties.clear();
    } else {
      for (final k in keys) {
        _properties.remove(k);
      }
    }
  }

  /// Wired by the SDK so a registered test device gets console tests instantly.
  void attachRealtime(NexusRealtime realtime) => _realtime = realtime;
  final Set<String> _shownThisSession = {};
  Map<String, int> _counts = {};
  bool _countsLoaded = false;

  /// All active in-app messages for the tenant.
  List<NexusInAppMessage> get active => List.unmodifiable(_active);

  static const _prefsKey = 'nexus_inapp_counts';

  Future<void> _loadCounts() async {
    if (_countsLoaded) return;
    _countsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey) ?? const [];
      _counts = {
        for (final e in raw)
          if (e.contains('=')) e.split('=').first: int.tryParse(e.split('=').last) ?? 0,
      };
    } catch (_) {}
  }

  Future<void> _bumpCount(String id) async {
    _counts[id] = (_counts[id] ?? 0) + 1;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, _counts.entries.map((e) => '${e.key}=${e.value}').toList());
    } catch (_) {}
  }

  /// Fetch the active messages; on success, auto-show a session-start message.
  Future<List<NexusInAppMessage>> fetch() async {
    await _loadCounts();
    try {
      final res = await _http.post('/partner/inapp/active', {
        if (_id.distinctId != null) 'distinctId': _id.distinctId,
        'deviceKey': _id.deviceKey,
        'properties': _wireProperties(),
        'context': _context(),
      });
      final list = (res?['messages'] as List?) ?? const [];
      final all = list.whereType<Map>().map((m) => NexusInAppMessage.fromJson(m.cast<String, dynamic>())).toList();
      final tests = all.where((m) => m.isTest).toList();
      _active = all.where((m) => !m.isTest).toList();
      NexusLog.debug('inapp: ${_active.length} active${tests.isEmpty ? '' : ', ${tests.length} test'}');
      _listenForTests(res?['testDevice'] == true);
      if (tests.isNotEmpty) {
        // A test from the console: show it now, whatever is on screen.
        NexusLog.info('inapp: showing test "${tests.first.id}"');
        current.value = tests.first;
      } else if (_cfg.inAppAutoShow) {
        _showNext(null);
      }
    } catch (e) {
      NexusLog.warn('inapp fetch failed: $e');
    }
    return _active;
  }

  /// Identify traits + contact details + [setProperties], JSON-safe.
  Map<String, Object?> _wireProperties() {
    final out = <String, Object?>{};
    void put(String k, Object? v) {
      if (v == null || v is String || v is num || v is bool) {
        out[k] = v;
      } else {
        out[k] = v.toString();
      }
    }

    _id.traits.forEach(put);
    if (_id.name != null) put('name', _id.name);
    if (_id.email != null) put('email', _id.email);
    if (_id.phone != null) put('phone', _id.phone);
    _properties.forEach(put);
    return out;
  }

  Map<String, Object?> _context() {
    final dc = _id.deviceContext;
    String? lang;
    try {
      lang = ui.PlatformDispatcher.instance.locale.toLanguageTag();
    } catch (_) {}
    return {
      if (dc['osType'] is String) 'platform': (dc['osType'] as String).toLowerCase(),
      if (dc['osVersion'] != null) 'osVersion': dc['osVersion'].toString(),
      if ((_cfg.appVersion ?? dc['appVersion']) != null) 'appVersion': (_cfg.appVersion ?? dc['appVersion']).toString(),
      'language': ?lang,
    };
  }

  /// Only devices registered in the console as test devices listen — joining
  /// a room is persisted and metered server-side, so every install doing it
  /// would cost the customer for a feature their team uses.
  void _listenForTests(bool isTestDevice) {
    final rt = _realtime;
    if (rt == null || !isTestDevice || !rt.isActive) return;
    final room = 'inapp-test:${_id.deviceKey}';
    if (_testRoom == room) return;
    _testRoom = room;
    rt.on('inapp.test', (_) {
      NexusLog.debug('inapp: test sent from the console — fetching');
      unawaited(fetch());
    });
    unawaited(rt.join(room));
    NexusLog.info('inapp: test device — console tests arrive instantly');
  }

  /// Called when an analytics event fires — shows a message triggered by it.
  void onEvent(String name) {
    if (current.value != null || !_cfg.inAppAutoShow) return;
    _showNext(name);
  }

  void _showNext(String? triggeredEvent) {
    if (current.value != null) return;
    for (final m in _active) {
      if (!_eligible(m)) continue;
      final type = m.triggerType;
      if (triggeredEvent == null) {
        // Fetch-time: show session-start / untriggered messages.
        if (type == null || type == 'session_start') {
          _present(m);
          return;
        }
      } else if (type == 'event' && m.triggerEvent == triggeredEvent) {
        _present(m);
        return;
      }
    }
  }

  bool _eligible(NexusInAppMessage m) {
    if (_shownThisSession.contains(m.id)) return false;
    if (m.maxDisplays != null && (_counts[m.id] ?? 0) >= m.maxDisplays!) return false;
    return true;
  }

  void _present(NexusInAppMessage m) {
    if (m.isTest) {
      current.value = m;
      return;
    }
    _shownThisSession.add(m.id);
    current.value = m;
    unawaited(_bumpCount(m.id));
    unawaited(_report(m, 'impression'));
    NexusLog.info('inapp: showing "${m.id}"');
  }

  /// Show a specific message now (bypasses trigger, still respects frequency).
  void show(NexusInAppMessage m) {
    if (!m.perSession || !_shownThisSession.contains(m.id)) _present(m);
  }

  /// Handle a button tap: report the click, surface the action, auto-track
  /// `event` actions, copy `copy` values, then dismiss. Tappable images in a
  /// designed message come through here too, with the image block's id.
  void tapButton(NexusInAppMessage m, NexusInAppButton b) {
    unawaited(_report(m, 'click', buttonId: b.id));
    final action = NexusInAppAction(
        messageId: m.id, buttonId: b.id, action: b.action, url: b.url, event: b.event, value: b.value, variantId: m.variantId);
    if (b.action == 'event' && (b.event ?? '').isNotEmpty) {
      onTrackEvent?.call(b.event!);
    }
    if (b.action == 'copy' && (b.value ?? '').isNotEmpty) {
      unawaited(Clipboard.setData(ClipboardData(text: b.value!)));
    }
    onAction?.call(action);
    close();
  }

  /// Dismiss the current message (X / backdrop tap).
  void dismiss(NexusInAppMessage m) {
    unawaited(_report(m, 'dismiss'));
    close();
  }

  /// Clear the message from the screen.
  void close() => current.value = null;

  /// Wired by the SDK to the analytics `track()` for `event`-action buttons.
  void Function(String event)? onTrackEvent;

  Future<void> _report(NexusInAppMessage m, String type, {String? buttonId}) async {
    // Tests are previews — the server ignores them too, but don't send them.
    if (m.isTest) return;
    try {
      await _http.post('/partner/inapp/event', {
        'messageId': m.id,
        'type': type,
        'buttonId': ?buttonId,
        'distinctId': ?_id.distinctId,
        // The install + variant let the console attribute A/B results and goals.
        'deviceKey': _id.deviceKey,
        'variantId': ?m.variantId,
      });
    } catch (_) {/* best-effort */}
  }

  void dispose() => current.dispose();
}
