/// Automatic network capture. Real implementation on `dart:io` platforms
/// (mobile/desktop) via HttpOverrides; a no-op stub on web.
library;

export 'network_capture_stub.dart'
    if (dart.library.io) 'network_capture_io.dart';
