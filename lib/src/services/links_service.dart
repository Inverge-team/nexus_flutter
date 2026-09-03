import '../http_client.dart';
import '../identity.dart';

/// Deep linking & attribution (OneLink-style). On first open, report the
/// install/open so the backend attributes it and returns the deferred deep-link
/// data.
class NexusLinks {
  NexusLinks(this._http, this._id);

  final NexusHttp _http;
  final NexusIdentity _id;

  /// Report a conversion. Pass [clickId] (from the link) for deterministic
  /// attribution; otherwise the server matches by fingerprint. Returns the
  /// matched link's deep-link data (or null if unattributed).
  Future<Map<String, dynamic>?> attribute({
    String type = 'install',
    String? clickId,
    String? name,
    String? platform,
    Map<String, Object?>? properties,
  }) async {
    final res = await _http.post('/partner/links/attribute', {
      'type': type,
      'clickId': ?clickId,
      'name': ?name,
      'platform': ?platform,
      if (_id.distinctId != null) 'distinctId': _id.distinctId,
      'deviceId': _id.deviceKey,
      'sessionKey': _id.sessionKey,
      'properties': ?properties,
    });
    final data = (res?['data'] ?? res) as Map<String, dynamic>?;
    return data?['link'] as Map<String, dynamic>?;
  }

  /// Convenience: parse a deep-link [uri] for `link_click_id` and attribute an
  /// open, returning the deep-link data.
  Future<Map<String, dynamic>?> handleDeepLink(
    Uri uri, {
    String type = 'open',
  }) {
    final clickId = uri.queryParameters['link_click_id'];
    return attribute(type: type, clickId: clickId);
  }
}
