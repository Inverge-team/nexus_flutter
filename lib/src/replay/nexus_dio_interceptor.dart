import 'package:dio/dio.dart';

import '../nexus.dart';
import 'network_capture.dart';

/// A Dio interceptor that feeds every request into session replay's **Network**
/// tab — method, URL, status, duration and response size.
///
/// ```dart
/// import 'package:nexus_flutter/nexus_dio.dart';
///
/// dio.interceptors.add(NexusDioInterceptor());
/// ```
///
/// A no-op until [Nexus] is initialised and replay is recording. Add it last so
/// it observes the final request/response (after your auth/retry interceptors).
class NexusDioInterceptor extends Interceptor {
  static const _startKey = 'nexus_start_ms';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startKey] = DateTime.now().millisecondsSinceEpoch;
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _record(response.requestOptions, response.statusCode ?? 0, response);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _record(err.requestOptions, err.response?.statusCode ?? 0, err.response);
    handler.next(err);
  }

  void _record(
    RequestOptions options,
    int status,
    Response<dynamic>? response,
  ) {
    if (!Nexus.isInitialized) return;
    // Automatic HttpOverrides capture already observes this request (Dio uses
    // dart:io) — skip to avoid double-recording.
    if (NexusNetworkCapture.isActive) return;
    final start = options.extra[_startKey];
    final duration = start is int
        ? DateTime.now().millisecondsSinceEpoch - start
        : 0;

    int? size;
    final len = response?.headers.value(Headers.contentLengthHeader);
    if (len != null) size = int.tryParse(len);

    Nexus.instance.replay.recordNetwork(
      url: options.uri.toString(),
      method: options.method,
      status: status,
      durationMs: duration,
      size: size,
    );
  }
}
