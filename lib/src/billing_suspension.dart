import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// The billing-suspension circuit breaker, shared by everything in the app that
/// calls Nexus, and remembered across app launches.
///
/// When the API answers 402 `billing_suspended` (an overdue invoice), the SDK
/// stops calling it for the pause the API asks for (`details.retryAfterSeconds`,
/// default 5 minutes): calls made meanwhile are refused locally, with no
/// request, and telemetry is dropped. When the pause ends ONE request goes out
/// as a probe (holding a short lease so concurrent callers keep waiting): a 402
/// starts a new pause, any other answer means access is back.
///
/// On mobile every installed app is a client, so without this a suspended
/// account's whole user base keeps calling the API at full rate — and
/// reconnecting sockets every few seconds. The pause is persisted so an app
/// restart doesn't skip it.
///
/// Messaging is exempt: it is paid from its own prepaid wallet and never
/// suspended; its 402 `insufficient_balance` is not a suspension.
class NexusBillingSuspension {
  NexusBillingSuspension._();

  static final NexusBillingSuspension instance = NexusBillingSuspension._();

  static const int defaultSeconds = 300;
  static const int _minSeconds = 30;
  static const int _maxSeconds = 3600;
  static const Duration _probeLease = Duration(seconds: 30);
  static const String _prefsPrefix = 'nexus_billing_suspended_';

  /// key → pause end (epoch ms).
  final Map<String, int> _pauses = {};

  /// Identifies one API key on one base URL without keeping the key itself.
  static String keyFor(String baseUrl, String apiKey) {
    // FNV-1a (32-bit) — stable across runs, unlike String.hashCode.
    var h = 0x811c9dc5;
    final s = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}|$apiKey';
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16);
  }

  /// Whether [path] is billed from a prepaid wallet and so never suspended.
  static bool isExempt(String path) => RegExp(r'^/partner/messaging(?:[/?]|$)').hasMatch(path);

  /// Whether an API answer is the billing-suspension refusal.
  static bool isSuspension(int status, Object? code) => status == 402 && code == 'billing_suspended';

  /// Load a pause persisted by a previous launch (call once at init).
  Future<void> restore(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final until = prefs.getInt('$_prefsPrefix$key');
      if (until != null && !_pauses.containsKey(key)) _pauses[key] = until;
    } catch (_) {
      // no storage — memory still holds a pause from this run
    }
  }

  /// Time the pause still has to run ([Duration.zero] = not paused). Read-only.
  Duration remaining(String key, [String path = '']) {
    if (path.isNotEmpty && isExempt(path)) return Duration.zero;
    final until = _pauses[key];
    if (until == null) return Duration.zero;
    final left = until - DateTime.now().millisecondsSinceEpoch;
    return left > 0 ? Duration(milliseconds: left) : Duration.zero;
  }

  /// Before a request: true to send it, false to refuse it locally. When a
  /// pause has just ended, the caller becomes the probe.
  bool begin(String key, String path) {
    if (isExempt(path)) return true;
    final until = _pauses[key];
    if (until == null) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (until > now) return false;
    _pauses[key] = now + _probeLease.inMilliseconds; // not persisted: a lease
    return true;
  }

  /// After an HTTP answer: a suspension starts (or extends) the pause and
  /// returns its length in seconds; any other answer lifts it.
  int? record(String key, String path, int status, {Object? code, Object? details}) {
    if (isSuspension(status, code)) {
      final raw = details is Map ? details['retryAfterSeconds'] : null;
      final seconds = (raw is num ? raw.toInt() : defaultSeconds).clamp(_minSeconds, _maxSeconds);
      final until = DateTime.now().millisecondsSinceEpoch + seconds * 1000;
      _pauses[key] = until;
      unawaited(_save(key, until));
      return seconds;
    }
    if (!isExempt(path) && _pauses.remove(key) != null) unawaited(_save(key, null));
    return null;
  }

  /// Forget every pause (tests; or right after settling an invoice).
  void reset() {
    for (final key in _pauses.keys.toList()) {
      unawaited(_save(key, null));
    }
    _pauses.clear();
  }

  /// The message for a call refused locally.
  static String message(Duration remaining) =>
      'API access is suspended for an overdue invoice. Nexus calls are paused for '
      '${remaining.inSeconds < 1 ? 1 : remaining.inSeconds} more seconds; settle the outstanding balance to restore access.';

  Future<void> _save(String key, int? until) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (until == null) {
        await prefs.remove('$_prefsPrefix$key');
      } else {
        await prefs.setInt('$_prefsPrefix$key', until);
      }
    } catch (_) {}
  }
}
