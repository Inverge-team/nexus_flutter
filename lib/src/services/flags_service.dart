import '../config.dart';
import '../http_client.dart';
import '../identity.dart';

/// Feature flags & remote config. Call [load] to evaluate all flags for the
/// current user, then read them synchronously.
class NexusFlags {
  NexusFlags(this._http, this._id, this._cfg);

  final NexusHttp _http;
  final NexusIdentity _id;
  final NexusConfig _cfg;

  Map<String, Object?> _flags = {};
  Map<String, Object?> _payloads = {};

  /// Evaluate every flag for the current person + properties and cache the result.
  Future<void> load({Map<String, Object?>? properties}) async {
    if (_id.distinctId == null) return;
    final res = await _http.post('/partner/flags/evaluate', {
      'distinctId': _id.distinctId,
      'properties': {..._cfg.defaultProperties, ..._id.traits, ...?properties},
    });
    final data = (res?['data'] ?? res) as Map<String, dynamic>?;
    if (data == null) return;
    _flags = Map<String, Object?>.from(data['flags'] as Map? ?? {});
    _payloads = Map<String, Object?>.from(data['payloads'] as Map? ?? {});
  }

  /// True when a boolean flag is on, or a multivariate flag has any variant.
  bool isEnabled(String key) {
    final v = _flags[key];
    return v == true || (v is String && v.isNotEmpty);
  }

  /// The variant key for a multivariate flag, or null.
  String? variant(String key) =>
      _flags[key] is String ? _flags[key] as String : null;

  /// The remote-config payload for a flag, if any.
  Object? payload(String key) => _payloads[key];

  Map<String, Object?> get all => Map.unmodifiable(_flags);
}
