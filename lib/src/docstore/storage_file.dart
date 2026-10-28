import 'dart:convert';
import 'dart:io';

import 'offline.dart';

/// One JSON file per entry under [directory] — for large offline replicas
/// (tens of thousands of documents). Native platforms only. Pass a directory
/// you own, e.g. `Directory('${(await getApplicationSupportDirectory()).path}/docstore')`
/// from `path_provider`.
class FileDocStoreStorage implements DocStoreStorage {
  FileDocStoreStorage(this.directory);
  final Directory directory;

  // Keys contain ':' and '/'; base64url keeps them filename-safe and reversible.
  File _file(String key) => File('${directory.path}/${base64Url.encode(utf8.encode(key))}.json');
  String _key(File f) => utf8.decode(base64Url.decode(f.uri.pathSegments.last.replaceAll('.json', '')));

  @override
  Future<Object?> get(String key) async {
    final f = _file(key);
    return await f.exists() ? jsonDecode(await f.readAsString()) : null;
  }

  @override
  Future<void> set(String key, Object? value) async {
    await directory.create(recursive: true);
    // Write-then-rename so a crash mid-write never leaves a torn document.
    final f = _file(key);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> delete(String key) async {
    final f = _file(key);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<List<MapEntry<String, Object?>>> entries(String prefix) async {
    if (!await directory.exists()) return const [];
    final out = <MapEntry<String, Object?>>[];
    await for (final e in directory.list()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      final key = _key(e);
      if (key.startsWith(prefix)) out.add(MapEntry(key, jsonDecode(await e.readAsString())));
    }
    return out;
  }
}
