import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_flutter/nexus_dio.dart';

/// Canned adapter so tests don't hit the network.
class _FakeAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      'ok',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
        Headers.contentLengthHeader: ['2'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Always fails, to exercise the interceptor's onError path.
class _ErrorAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: 'boom',
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'integrates into the Dio chain and is a safe no-op before init',
    () async {
      final dio = Dio()..httpClientAdapter = _FakeAdapter();
      dio.interceptors.add(NexusDioInterceptor());

      final res = await dio.get<String>('https://example.com/x');

      expect(res.statusCode, 200);
      // onRequest stamped a start time on the request it observed.
      expect(res.requestOptions.extra['nexus_start_ms'], isA<int>());
    },
  );

  test('propagates errors through onError without swallowing them', () async {
    final dio = Dio()
      ..httpClientAdapter = _ErrorAdapter()
      ..interceptors.add(NexusDioInterceptor());
    await expectLater(
      dio.get<void>('https://example.com/fail'),
      throwsA(isA<DioException>()),
    );
  });
}
