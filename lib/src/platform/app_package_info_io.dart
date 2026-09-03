import 'package:package_info_plus/package_info_plus.dart';

/// Native platforms: read the app's package metadata via `package_info_plus`.
Future<Map<String, Object?>> loadPackageInfo() async {
  final pkg = await PackageInfo.fromPlatform();
  return <String, Object?>{
    'appName': pkg.appName,
    'packageName': pkg.packageName,
    'version': pkg.version,
    'buildNumber': pkg.buildNumber,
    'installerStore': pkg.installerStore,
  };
}
