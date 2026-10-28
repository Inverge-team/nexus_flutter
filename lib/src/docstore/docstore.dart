import 'api.dart';
import 'client.dart';
import 'live.dart';
import 'offline.dart';

/// Nexus DocStore — the document database — with its offline (local-first) mode.
class NexusDocStore extends DocStore {
  NexusDocStore._(super.http, super.liveFactory);

  /// Create a client. Inside an app prefer `Nexus.instance.docStore(...)`,
  /// which reuses the SDK's API key and base URL.
  factory NexusDocStore(DocStoreOptions options, {bool Function()? enabled}) {
    if (options.apiKey.isEmpty) throw ArgumentError('NexusDocStore: apiKey is required');
    return NexusDocStore._(DocStoreHttp(options, enabled: enabled), () => DocStoreLive(options));
  }

  /// A local-first replica of [collections]: instant reads and writes that
  /// work offline, synced in the background with field-level merge.
  OfflineStore offline({
    required List<String> collections,
    DocStoreStorage? storage,
    String? deviceId,
    Duration pullInterval = const Duration(seconds: 30),
    bool live = true,
    void Function(OfflineConflict conflict)? onConflict,
  }) =>
      OfflineStore(this, collections: collections, storage: storage, deviceId: deviceId, pullInterval: pullInterval, live: live, onConflict: onConflict);
}
