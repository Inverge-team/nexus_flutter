/// Reports one observed request. `size` is null when the length is unknown.
typedef NetworkRecord = void Function({
  required String url,
  required String method,
  required int status,
  required int durationMs,
  int? size,
});

/// Web fallback: there is no `dart:io` `HttpOverrides` in the browser (requests
/// go through fetch/XHR), so automatic capture is a no-op here. Use the manual
/// [recordNetwork] API or a Dio interceptor on web.
class NexusNetworkCapture {
  static bool get isActive => false;

  static void install({
    required bool Function() isRecording,
    required bool Function(Uri url) ignore,
    required NetworkRecord record,
  }) {}

  static void uninstall() {}
}
