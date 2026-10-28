import 'offline.dart';

/// File storage is not available on the web — use the default
/// [SharedPreferencesDocStoreStorage] (or [MemoryDocStoreStorage]) there.
class FileDocStoreStorage implements DocStoreStorage {
  FileDocStoreStorage(Object directory) {
    throw UnsupportedError('FileDocStoreStorage is not available on the web');
  }
  @override
  Future<Object?> get(String key) => throw UnimplementedError();
  @override
  Future<void> set(String key, Object? value) => throw UnimplementedError();
  @override
  Future<void> delete(String key) => throw UnimplementedError();
  @override
  Future<List<MapEntry<String, Object?>>> entries(String prefix) => throw UnimplementedError();
}
