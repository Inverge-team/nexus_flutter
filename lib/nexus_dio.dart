/// Dio integration for Nexus. Import this library **separately** from
/// `package:nexus_flutter/nexus.dart` so apps that don't use Dio aren't affected.
///
/// ```dart
/// import 'package:nexus_flutter/nexus_dio.dart';
///
/// dio.interceptors.add(NexusDioInterceptor());          // session replay network tab
/// dio.interceptors.add(NexusShieldDioInterceptor());    // Shield: device-bound request signing
/// ```
library;

export 'src/replay/nexus_dio_interceptor.dart' show NexusDioInterceptor;
export 'src/shield/shield_dio_interceptor.dart' show NexusShieldDioInterceptor;
