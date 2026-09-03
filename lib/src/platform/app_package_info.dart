/// App package metadata (name, version, build), resolved per platform.
///
/// `package_info_plus` pulls in `dart:io` through its desktop implementations,
/// which is not WASM-compatible. To keep the SDK WASM-safe we load it only on
/// native (`dart:library.io`) platforms and fall back to an empty map on
/// web/WASM — supply the version there via `NexusConfig.appVersion`.
library;

export 'app_package_info_stub.dart'
    if (dart.library.io) 'app_package_info_io.dart';
