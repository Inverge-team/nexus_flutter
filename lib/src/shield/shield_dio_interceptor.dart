import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../nexus.dart';

/// Adds Nexus Shield headers (`X-Nexus-Shield` + a single-use `DPoP` proof)
/// to every request this Dio instance sends, so your backend can verify the
/// request comes from your genuine app on a real device.
///
/// ```dart
/// import 'package:nexus_flutter/nexus_dio.dart';
///
/// dio.interceptors.add(NexusShieldDioInterceptor());
/// ```
///
/// A no-op until [Nexus] is initialised with `shieldEnabled: true`, and when no
/// token can be had right now (the request is sent unsigned — your backend's
/// policy decides). Never throws.
///
/// Add it LAST, after interceptors that change the method/URL/body, since the
/// proof covers exactly the request that leaves the device.
class NexusShieldDioInterceptor extends Interceptor {
  NexusShieldDioInterceptor({this.hosts});

  /// Only sign requests to these hosts (default: every request on this Dio).
  /// Keeps third-party calls (maps, analytics) from carrying your token.
  final Set<String>? hosts;

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    try {
      final uri = options.uri;
      final auto = Nexus.isInitialized && Nexus.instance.config.shieldHosts.isNotEmpty && !kIsWeb;
      // With `shieldHosts` set, dart:io requests are already signed by the SDK;
      // signing here too would burn two proofs per request. Only sign here when
      // that automatic path is off (or on web, where it can't run).
      if (!auto && Nexus.isInitialized && Nexus.instance.config.shieldEnabled && (hosts == null || hosts!.contains(uri.host))) {
        final headers = await Nexus.instance.shield.headers(method: options.method, url: uri, body: _bodyBytes(options.data));
        options.headers.addAll(headers);
      }
    } catch (_) {
      // Shield must never break a request.
    }
    handler.next(options);
  }

  /// Bind the proof to the body only when we know the exact bytes Dio will
  /// send. Maps/lists are encoded later by Dio's transformer, so they are not
  /// bound (the proof still binds method + URL + token).
  static List<int>? _bodyBytes(Object? data) {
    if (data is String) return utf8.encode(data);
    if (data is List<int>) return data;
    return null;
  }
}
