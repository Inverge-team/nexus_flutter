import 'dart:async';
import 'dart:ui' as ui;

import '../config.dart';
import '../http_client.dart';
import '../identity.dart';
import '../logging.dart';
import 'realtime_service.dart';

/// Room the server pings when a new template is published (realtime updates).
const String kRemoteConfigRoom = '__remote_config';

/// Firebase-style Remote Config. Fetches the active template for this app
/// instance, resolves conditional values server-side, and exposes typed getters
/// with in-app defaults as the fallback.
///
/// ```dart
/// nexus.remoteConfig.setDefaults({'welcome': 'Hi', 'max_items': 10});
/// await nexus.remoteConfig.fetch();
/// final msg = nexus.remoteConfig.getString('welcome');
/// ```
class NexusRemoteConfig {
  NexusRemoteConfig(this._http, this._id, this._cfg) {
    _defaults = {..._cfg.remoteConfigDefaults};
  }

  final NexusHttp _http;
  final NexusIdentity _id;
  final NexusConfig _cfg;

  final Map<String, Object?> _values = {};
  final Map<String, String?> _sources = {};
  final Map<String, Object?> _attributes = {};
  Map<String, Object?> _defaults = {};

  final StreamController<void> _changes = StreamController<void>.broadcast();
  NexusRealtime? _realtime;

  String? _etag;
  int _version = 0;
  DateTime? _lastFetch;

  /// Emits after every fetch that changes the active values.
  Stream<void> get onChange => _changes.stream;

  /// The active template version last fetched (0 until first fetch).
  int get version => _version;
  DateTime? get lastFetchTime => _lastFetch;

  /// Set in-app fallback values (used until the server provides a value).
  /// Merges with any existing defaults. Mirrors Firebase `setDefaults`.
  void setDefaults(Map<String, Object?> defaults) =>
      _defaults = {..._defaults, ...defaults};

  /// Custom targeting attributes sent with every fetch (e.g. `governorate`,
  /// `plan`, `segment`). These feed "Custom attribute" conditions on the server.
  /// Merges with existing attributes; call [clearAttributes] to reset. Mirrors
  /// Firebase custom signals. Values must be string/number/bool.
  void setAttributes(Map<String, Object?> attributes) =>
      _attributes.addAll(attributes);

  /// Set (or replace) a single custom targeting attribute. Pass `null` to remove.
  void setAttribute(String key, Object? value) {
    if (value == null) {
      _attributes.remove(key);
    } else {
      _attributes[key] = value;
    }
  }

  /// The custom targeting attributes currently sent with fetches.
  Map<String, Object?> get attributes => Map.unmodifiable(_attributes);

  void clearAttributes() => _attributes.clear();

  /// Fetch the active template and activate it. Returns `true` when the values
  /// changed since the last fetch. [attributes] are merged (for this fetch only)
  /// over the persistent ones set via [setAttributes]. Best-effort — never throws.
  Future<bool> fetch({Map<String, Object?>? attributes}) async {
    final res = await _http.post(
      '/partner/remote-config/fetch',
      _buildContext(attributes),
      extraHeaders: _etag != null ? {'if-none-match': _etag!} : null,
    );
    if (res == null) return false; // request failed — keep current values

    // Un-enveloped partner response; `data` fallback for safety.
    final body =
        (res['parameters'] != null ||
            res['notModified'] != null ||
            res['throttled'] != null)
        ? res
        : (res['data'] as Map<String, dynamic>? ?? res);

    if (body['notModified'] == true || body['throttled'] == true) {
      _lastFetch = DateTime.now();
      return false;
    }

    final params = body['parameters'] as Map<String, dynamic>? ?? {};
    _values.clear();
    _sources.clear();
    params.forEach((key, raw) {
      final entry = raw as Map<String, dynamic>;
      _values[key] = entry['value'];
      _sources[key] = entry['source'] as String?;
    });
    _etag = body['etag'] as String? ?? _etag;
    _version = (body['version'] as num?)?.toInt() ?? _version;
    _lastFetch = DateTime.now();
    NexusLog.debug(
      'remote-config: fetched v$_version (${_values.length} params)',
    );
    if (!_changes.isClosed) _changes.add(null);
    return true;
  }

  // --- typed getters ------------------------------------------------------

  /// The raw value for [key] (server value, else in-app default, else null).
  Object? getValue(String key) =>
      _values.containsKey(key) ? _values[key] : _defaults[key];

  String getString(String key, [String fallback = '']) {
    final v = getValue(key);
    if (v == null) return fallback;
    return v is String ? v : v.toString();
  }

  bool getBool(String key, [bool fallback = false]) {
    final v = getValue(key);
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v == 'true' || v == '1';
    return fallback;
  }

  int getInt(String key, [int fallback = 0]) {
    final v = getValue(key);
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  double getDouble(String key, [double fallback = 0]) {
    final v = getValue(key);
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  /// A JSON value (Map/List) for [key], or [fallback] when absent.
  Object? getJson(String key, [Object? fallback]) => getValue(key) ?? fallback;

  /// The condition that supplied [key]'s value (`null` when the default applied).
  String? sourceOf(String key) => _sources[key];

  /// Every currently-active key → value (server values overlaid on defaults).
  Map<String, Object?> getAll() => {..._defaults, ..._values};

  // --- realtime -----------------------------------------------------------

  /// Subscribe to server-pushed config updates: on a new publish, re-fetch.
  /// Requires an active realtime connection. Safe to call more than once.
  Future<void> subscribeRealtime(NexusRealtime realtime) async {
    if (_realtime != null) return;
    _realtime = realtime;
    try {
      await realtime.join(kRemoteConfigRoom);
      realtime.on('config_updated', (_) {
        NexusLog.debug('remote-config: realtime update — re-fetching');
        unawaited(fetch());
      });
      NexusLog.info('remote-config: realtime updates on');
    } catch (e, st) {
      NexusLog.warn('remote-config: realtime subscribe failed: $e');
      NexusLog.debug('$st');
    }
  }

  Future<void> unsubscribeRealtime() async {
    final rt = _realtime;
    if (rt == null) return;
    rt.off('config_updated');
    try {
      await rt.leave(kRemoteConfigRoom);
    } catch (_) {}
    _realtime = null;
  }

  Map<String, Object?> _buildContext(Map<String, Object?>? oneShotAttributes) {
    final dc = _id.deviceContext;
    return <String, Object?>{
      'appInstanceId': _id.deviceKey,
      if ((_cfg.appVersion ?? dc['appVersion']) != null)
        'appVersion': _cfg.appVersion ?? dc['appVersion'],
      if (dc['osType'] is String)
        'platform': (dc['osType'] as String).toLowerCase(),
      if (dc['osVersion'] is String) 'osVersion': dc['osVersion'],
      ..._locale(),
      // Custom attributes feed "Custom attribute" conditions. Later entries win:
      // config defaults < identity traits < persistent attributes < this fetch's.
      'userProperties': {
        ..._cfg.defaultProperties,
        ..._id.traits,
        ..._attributes,
        ...?oneShotAttributes,
      },
    };
  }

  Map<String, Object?> _locale() {
    try {
      final l = ui.PlatformDispatcher.instance.locale;
      return {
        'language': l.languageCode,
        if (l.countryCode != null && l.countryCode!.isNotEmpty)
          'country': l.countryCode,
      };
    } catch (_) {
      return const {};
    }
  }

  void dispose() {
    unawaited(unsubscribeRealtime());
    if (!_changes.isClosed) _changes.close();
  }
}
