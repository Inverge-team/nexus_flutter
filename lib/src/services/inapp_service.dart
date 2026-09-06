import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../http_client.dart';
import '../identity.dart';
import '../inapp/inapp_models.dart';
import '../logging.dart';

/// In-app messages (OneSignal-style). Fetches the active messages for the tenant,
/// evaluates triggers (session start / custom event) and frequency caps locally,
/// requests display, and reports impressions/clicks. Rendering is done by
/// `NexusInAppOverlay` (default UI) or your own widget driven by [current].
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
      });
      final list = (res?['messages'] as List?) ?? const [];
      _active = list.whereType<Map>().map((m) => NexusInAppMessage.fromJson(m.cast<String, dynamic>())).toList();
      NexusLog.debug('inapp: ${_active.length} active');
      if (_cfg.inAppAutoShow) _showNext(null);
    } catch (e) {
      NexusLog.warn('inapp fetch failed: $e');
    }
    return _active;
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
    _shownThisSession.add(m.id);
    current.value = m;
    unawaited(_bumpCount(m.id));
    unawaited(_report(m.id, 'impression'));
    NexusLog.info('inapp: showing "${m.id}"');
  }

  /// Show a specific message now (bypasses trigger, still respects frequency).
  void show(NexusInAppMessage m) {
    if (!m.perSession || !_shownThisSession.contains(m.id)) _present(m);
  }

  /// Handle a button tap: report the click, surface the action, auto-track
  /// `event` actions, then dismiss.
  void tapButton(NexusInAppMessage m, NexusInAppButton b) {
    unawaited(_report(m.id, 'click', buttonId: b.id));
    final action = NexusInAppAction(messageId: m.id, buttonId: b.id, action: b.action, url: b.url, event: b.event);
    if (b.action == 'event' && (b.event ?? '').isNotEmpty) {
      onTrackEvent?.call(b.event!);
    }
    onAction?.call(action);
    close();
  }

  /// Dismiss the current message (X / backdrop tap).
  void dismiss(NexusInAppMessage m) {
    unawaited(_report(m.id, 'dismiss'));
    close();
  }

  /// Clear the message from the screen.
  void close() => current.value = null;

  /// Wired by the SDK to the analytics `track()` for `event`-action buttons.
  void Function(String event)? onTrackEvent;

  Future<void> _report(String messageId, String type, {String? buttonId}) async {
    try {
      await _http.post('/partner/inapp/event', {
        'messageId': messageId,
        'type': type,
        'buttonId': ?buttonId,
        'distinctId': ?_id.distinctId,
      });
    } catch (_) {/* best-effort */}
  }

  void dispose() => current.dispose();
}
