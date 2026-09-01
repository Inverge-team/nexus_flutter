/// Dio integration for Nexus. Import this library **separately** from
/// `package:nexus_flutter/nexus.dart` so apps that don't use Dio aren't affected.
///
/// ```dart
/// import 'package:nexus_flutter/nexus_dio.dart';
///
/// dio.interceptors.add(NexusDioInterceptor());
/// ```
library;

export 'src/replay/nexus_dio_interceptor.dart' show NexusDioInterceptor;
