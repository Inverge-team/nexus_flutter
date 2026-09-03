/// Web/WASM: no `package_info_plus` (it imports `dart:io`). Pass the version
/// explicitly via `NexusConfig.appVersion` when you need it on web.
Future<Map<String, Object?>> loadPackageInfo() async => <String, Object?>{};
