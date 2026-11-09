import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../nexus_platform_interface.dart';
import '../shield/jose.dart';

/// What Push Authentication persists between runs (SharedPreferences) — enough
/// for the BACKGROUND isolate to answer a silent challenge while the app is
/// killed. Nothing secret: the API key ships in the app anyway, the factor id
/// is useless without the hardware key, and the channel only carries hints.
class PushAuthState {
  PushAuthState({
    required this.apiKey,
    required this.baseUrl,
    required this.prefix,
    this.factorId,
    this.identity,
    this.channel,
    this.silentApproval = true,
    this.presenceJkt,
    this.silentJwk,
  });

  final String apiKey;
  final String baseUrl;
  final String prefix;
  String? factorId;
  String? identity;
  String? channel;
  bool silentApproval;
  String? presenceJkt;
  Map<String, String>? silentJwk;

  bool get enrolled => factorId != null && silentJwk != null;

  Map<String, Object?> toJson() => {
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'prefix': prefix,
        'factorId': factorId,
        'identity': identity,
        'channel': channel,
        'silentApproval': silentApproval,
        'presenceJkt': presenceJkt,
        'silentJwk': silentJwk,
      };

  static PushAuthState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, Object?>();
    if (j['apiKey'] is! String || j['baseUrl'] is! String) return null;
    return PushAuthState(
      apiKey: j['apiKey'] as String,
      baseUrl: j['baseUrl'] as String,
      prefix: (j['prefix'] as String?) ?? 'nexus_push_auth',
      factorId: j['factorId'] as String?,
      identity: j['identity'] as String?,
      channel: j['channel'] as String?,
      silentApproval: (j['silentApproval'] as bool?) ?? true,
      presenceJkt: j['presenceJkt'] as String?,
      silentJwk: (j['silentJwk'] as Map?)?.cast<String, String>(),
    );
  }
}

/// A Push Authentication API error with the backend's stable code.
class NexusPushAuthException implements Exception {
  NexusPushAuthException(this.code, this.message, {this.status, this.reason});

  /// e.g. `enrollment_failed`, `challenge_not_pending`, `response_invalid`,
  /// `cancelled` (the user dismissed the prompt), `unsupported`, `network`.
  final String code;
  final String message;
  final int? status;

  /// The detailed reason (e.g. `token_expired`, `details_mismatch`).
  final String? reason;

  @override
  String toString() => 'NexusPushAuthException($code${reason != null ? '/$reason' : ''}): $message';
}

/// The device side of the wire protocol: every request carries a single-use
/// DPoP-style proof from the factor's SILENT key; there is no bearer token.
class PushAuthApi {
  PushAuthApi(this.state, {http.Client? client}) : _client = client ?? http.Client();

  final PushAuthState state;
  final http.Client _client;

  static const _prefix = '/partner/push-auth';

  Future<Map<String, dynamic>> request(String method, String path, {Object? body, Map<String, String>? silentJwk}) async {
    final jwk = silentJwk ?? state.silentJwk;
    if (jwk == null) throw NexusPushAuthException('not_enrolled', 'This device is not enrolled');
    final url = Uri.parse('${state.baseUrl}$_prefix$path');
    final proof = await _proof(jwk, method, url);
    final headers = {'x-api-key': state.apiKey, 'content-type': 'application/json', 'dpop': proof};
    final http.Response res;
    try {
      final req = http.Request(method, url)..headers.addAll(headers);
      if (body != null) req.body = jsonEncode(body);
      res = await http.Response.fromStream(await _client.send(req)).timeout(const Duration(seconds: 20));
    } catch (e) {
      throw NexusPushAuthException('network', '$e');
    }
    Map<String, dynamic> decoded = const {};
    try {
      final d = res.body.isEmpty ? null : jsonDecode(res.body);
      if (d is Map<String, dynamic>) decoded = d;
    } catch (_) {}
    if (res.statusCode >= 400) {
      final err = (decoded['error'] as Map?)?.cast<String, Object?>() ?? const {};
      final details = (err['details'] as Map?)?.cast<String, Object?>();
      throw NexusPushAuthException(
        (err['code'] as String?) ?? 'http_${res.statusCode}',
        (err['message'] as String?) ?? 'HTTP ${res.statusCode}',
        status: res.statusCode,
        reason: details?['reason'] as String?,
      );
    }
    final data = decoded['data'];
    return data is Map<String, dynamic> ? data : decoded;
  }

  Future<String> _proof(Map<String, String> jwk, String method, Uri url) async {
    final header = b64urlJson({'typ': 'dpop+jwt', 'alg': 'ES256', 'jwk': jwk});
    final payload = b64urlJson({
      'jti': randomId(),
      'htm': method.toUpperCase(),
      'htu': '${url.scheme}://${url.authority}${url.path}',
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    return signJws('$header.$payload', presence: false);
  }

  /// Sign `<header>.<payload>` with one of the factor's keys → compact JWS.
  Future<String> signJws(String input, {required bool presence, Map<String, String?> prompt = const {}}) async {
    final data = Uint8List.fromList(utf8.encode(input));
    final der = presence
        ? await NexusPlatform.instance.pushAuthSignPresence(state.prefix, data, prompt: prompt)
        : await NexusPlatform.instance.pushAuthSignSilent(state.prefix, data);
    if (der == null) throw NexusPushAuthException('sign_failed', 'The device key could not sign');
    return '$input.${b64url(derToJose(der))}';
  }

  void close() => _client.close();
}
