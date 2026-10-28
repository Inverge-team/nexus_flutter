import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'client.dart';
import 'core.dart';

// ── storage ───────────────────────────────────────────────────────────────

/// Where the offline cache persists. Values are JSON-encodable.
abstract class DocStoreStorage {
  Future<Object?> get(String key);
  Future<void> set(String key, Object? value);
  Future<void> delete(String key);

  /// Every entry whose key starts with [prefix].
  Future<List<MapEntry<String, Object?>>> entries(String prefix);
}

/// In memory only (tests, or a cache that may vanish with the process).
class MemoryDocStoreStorage implements DocStoreStorage {
  final _m = <String, String>{};
  @override
  Future<Object?> get(String key) async => _m[key] == null ? null : jsonDecode(_m[key]!);
  @override
  Future<void> set(String key, Object? value) async => _m[key] = jsonEncode(value);
  @override
  Future<void> delete(String key) async => _m.remove(key);
  @override
  Future<List<MapEntry<String, Object?>>> entries(String prefix) async =>
      [for (final e in _m.entries) if (e.key.startsWith(prefix)) MapEntry(e.key, jsonDecode(e.value))];
}

/// Persistent on every platform via `shared_preferences` — the default. Fine
/// for typical app data (hundreds to a few thousand documents); for larger
/// replicas use [FileDocStoreStorage].
class SharedPreferencesDocStoreStorage implements DocStoreStorage {
  SharedPreferencesDocStoreStorage({this.namespace = 'nexus.docstore'});
  final String namespace;
  SharedPreferences? _prefs;
  Future<SharedPreferences> get _p async => _prefs ??= await SharedPreferences.getInstance();
  String _k(String key) => '$namespace:$key';

  @override
  Future<Object?> get(String key) async {
    final s = (await _p).getString(_k(key));
    return s == null ? null : jsonDecode(s);
  }

  @override
  Future<void> set(String key, Object? value) async => (await _p).setString(_k(key), jsonEncode(value));
  @override
  Future<void> delete(String key) async => (await _p).remove(_k(key));
  @override
  Future<List<MapEntry<String, Object?>>> entries(String prefix) async {
    final p = await _p;
    final full = _k(prefix);
    return [
      for (final k in p.getKeys())
        if (k.startsWith(full)) MapEntry(k.substring(namespace.length + 1), jsonDecode(p.getString(k) ?? 'null')),
    ];
  }
}

// ── model ─────────────────────────────────────────────────────────────────

class _LocalDoc {
  _LocalDoc(this.id, this.data, this.version, this.clock, this.createdAt, this.updatedAt);
  factory _LocalDoc.fromJson(Map m) => _LocalDoc('${m['id']}', (m['data'] as Map?)?.cast<String, Object?>(), (m['version'] as num).toInt(),
      ((m['clock'] as Map?) ?? const {}).cast<String, String>(), '${m['createdAt']}', '${m['updatedAt']}');
  final String id;
  JsonMap? data; // null = local delete awaiting acknowledgement
  int version;
  Map<String, String> clock;
  String createdAt;
  String updatedAt;
  Map<String, Object?> toJson() => {'id': id, 'data': data, 'version': version, 'clock': clock, 'createdAt': createdAt, 'updatedAt': updatedAt};
}

class _Outbox {
  _Outbox(this.collection, this.id, this.baseVersion, this.deleted, this.data, this.clock, this.rev);
  factory _Outbox.fromJson(Map m) => _Outbox('${m['collection']}', '${m['id']}', (m['baseVersion'] as num).toInt(), m['deleted'] == true,
      (m['data'] as Map?)?.cast<String, Object?>(), ((m['clock'] as Map?) ?? const {}).cast<String, String>(), (m['rev'] as num).toInt());
  final String collection;
  final String id;
  int baseVersion;
  final bool deleted;
  final JsonMap? data;
  final Map<String, String> clock;
  final int rev;
  Map<String, Object?> toJson() => {'collection': collection, 'id': id, 'baseVersion': baseVersion, 'deleted': deleted, 'data': data, 'clock': clock, 'rev': rev};
}

/// A local change the server did not take as-is.
class OfflineConflict {
  OfflineConflict(this.collection, this.id, this.kind, this.localData, this.serverData, {this.errorCode, this.errorMessage, this.conflictId});
  final String collection;
  final String id;

  /// `rejected` (server-wins collection), `parked` (manual strategy → conflict
  /// inbox) or `refused` (rules / schema / unique constraint said no).
  final String kind;
  final JsonMap? localData;
  final JsonMap? serverData;
  final String? errorCode;
  final String? errorMessage;
  final String? conflictId;
}

enum SyncStatus { idle, syncing, offline, error }

class LocalSnapshot {
  LocalSnapshot(this.id, this._data, this.version, this.hasPendingWrites, this.createdAt, this.updatedAt);
  final String id;
  final JsonMap? _data;
  final int version;

  /// True while a local change hasn't been acknowledged by the server.
  final bool hasPendingWrites;
  final DateTime createdAt;
  final DateTime updatedAt;
  bool get exists => _data != null;
  bool get fromCache => true;
  JsonMap? data() => _data == null ? null : jsonClone(_data);
  Object? get(String path) => getPath(_data, path);
}

// ── the engine ────────────────────────────────────────────────────────────

/// Local-first DocStore: reads and writes hit the on-device cache at once and
/// keep working offline; a background engine replicates. Pushes carry the
/// version each edit started from plus a hybrid logical clock per field, so the
/// server merges field-by-field; pulls fetch only what the user may read and
/// rebase pending local edits (newer field clock wins).
class OfflineStore {
  OfflineStore(this._store, {required this.collections, DocStoreStorage? storage, String? deviceId, this._pullInterval = const Duration(seconds: 30), bool live = true, this.onConflict})
      : _storage = storage ?? SharedPreferencesDocStoreStorage(),
        _liveSync = live {
    _ready = _load(deviceId);
  }

  final DocStore _store;
  final List<String> collections;
  final DocStoreStorage _storage;
  final Duration _pullInterval;
  final bool _liveSync;
  final void Function(OfflineConflict conflict)? onConflict;

  final _docs = <String, Map<String, _LocalDoc>>{};
  final _outbox = <String, _Outbox>{};
  final _changes = StreamController<String>.broadcast();
  final _statusCtl = StreamController<SyncStatus>.broadcast();
  late final Future<void> _ready;
  late Hlc _hlc;
  int _checkpoint = 0;
  int _rev = 0;
  Future<void>? _running;
  bool _again = false;
  Timer? _debounce;
  Timer? _interval;
  Timer? _retry;
  int _retries = 0;
  void Function()? _stopWatch;
  SyncStatus status = SyncStatus.idle;

  /// Local changes not yet acknowledged by the server.
  int get pending => _outbox.length;
  Stream<SyncStatus> get statusChanges => _statusCtl.stream;
  Future<void> get ready => _ready;

  Map<String, _LocalDoc> _col(String name) => _docs.putIfAbsent(name, () => {});

  Future<void> _load(String? deviceId) async {
    var node = deviceId ?? (await _storage.get('meta:node')) as String?;
    node ??= 'd${Random.secure().nextInt(1 << 32).toRadixString(36)}';
    await _storage.set('meta:node', node);
    final clean = node.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    _hlc = Hlc(clean.isEmpty ? 'device' : clean.substring(0, min(32, clean.length)));
    _checkpoint = ((await _storage.get('meta:checkpoint')) as num?)?.toInt() ?? 0;
    for (final e in await _storage.entries('doc:')) {
      final rest = e.key.substring(4);
      final i = rest.indexOf('/');
      final d = _LocalDoc.fromJson(e.value as Map);
      _col(rest.substring(0, i))[d.id] = d;
    }
    for (final e in await _storage.entries('out:')) {
      final o = _Outbox.fromJson(e.value as Map);
      _outbox['${o.collection}/${o.id}'] = o;
      _rev = max(_rev, o.rev);
    }
    _interval = Timer.periodic(_pullInterval, (_) => _schedule(Duration.zero));
    if (_liveSync) {
      try {
        _stopWatch = _store.live.watch(collections, () => _schedule(Duration.zero));
      } catch (_) {/* polling only */}
    }
    _schedule(Duration.zero);
  }

  void stop() {
    _interval?.cancel();
    _debounce?.cancel();
    _retry?.cancel();
    _stopWatch?.call();
  }

  /// Wipe the cache and the outbox (e.g. on sign-out). Unsynced changes are lost.
  Future<void> clear() async {
    for (final e in await _storage.entries('doc:')) {
      await _storage.delete(e.key);
    }
    for (final e in await _storage.entries('out:')) {
      await _storage.delete(e.key);
    }
    await _storage.delete('meta:checkpoint');
    _docs.clear();
    _outbox.clear();
    _checkpoint = 0;
    for (final c in collections) {
      _changes.add(c);
    }
  }

  LocalCollection collection(String name) {
    if (!collections.contains(name)) throw ArgumentError("'$name' is not replicated by this OfflineStore");
    return LocalCollection._(this, name, null, const [], null);
  }

  // ── sync loop ───────────────────────────────────────────────────────────

  /// Push local changes, then pull remote ones. Completes when caught up.
  Future<void> sync() async {
    await _ready;
    if (_running != null) {
      _again = true;
      return _running;
    }
    final run = () async {
      do {
        _again = false;
        _setStatus(SyncStatus.syncing);
        await _push();
        await _pull();
      } while (_again);
    }();
    _running = run.then((_) {
      _retries = 0;
      _setStatus(SyncStatus.idle);
    }, onError: (Object e) {
      final code = e is DocStoreException ? e.code : 'internal';
      _setStatus(code == 'network' ? SyncStatus.offline : SyncStatus.error);
      _retry?.cancel();
      _retry = Timer(Duration(milliseconds: min(60000, 1000 * pow(2, _retries++).toInt())), () => _schedule(Duration.zero));
    }).whenComplete(() => _running = null);
    return _running;
  }

  void _schedule(Duration delay) {
    _debounce?.cancel();
    _debounce = Timer(delay, () => sync());
  }

  Future<void> _push() async {
    while (_outbox.isNotEmpty) {
      final batch = _outbox.values.take(100).toList();
      final res = (await _store.http.request('POST', '/sync/push', body: {
        'clientId': _hlc.node,
        'changes': [
          for (final e in batch) {'collection': e.collection, 'id': e.id, 'baseVersion': e.baseVersion, 'deleted': e.deleted, if (e.data != null) 'data': e.data, 'clock': e.clock},
        ],
      })) as Map;
      for (final raw in (res['results'] as List)) {
        final r = (raw as Map).cast<String, Object?>();
        final i = (r['index'] as num).toInt();
        if (i < 0 || i >= batch.length) continue;
        final e = batch[i];
        final key = '${e.collection}/${e.id}';
        final still = _outbox[key]?.rev == e.rev;
        final doc = (r['doc'] as Map?)?.cast<String, Object?>();
        final version = (r['version'] as num?)?.toInt();
        final status = r['status'];
        if (status == 'ok' || status == 'noop') {
          if (still) {
            await _dropOutbox(key);
            await _adopt(e.collection, e.id, doc, version ?? e.baseVersion);
          } else {
            final next = _outbox[key]!..baseVersion = version ?? _outbox[key]!.baseVersion;
            await _storage.set('out:$key', next.toJson());
          }
          continue;
        }
        final kind = status == 'rejected' ? 'rejected' : status == 'conflict' ? 'parked' : 'refused';
        if (still) await _dropOutbox(key);
        final err = (r['error'] as Map?)?.cast<String, Object?>();
        onConflict?.call(OfflineConflict(e.collection, e.id, kind, e.deleted ? null : e.data, (doc?['data'] as Map?)?.cast<String, Object?>(),
            errorCode: err?['code'] as String?, errorMessage: err?['message'] as String?, conflictId: r['conflictId'] as String?));
        if (doc != null || r['deleted'] == true) {
          await _adopt(e.collection, e.id, doc, version ?? 0);
        } else if (kind == 'refused') {
          await _refetch(e.collection, e.id);
        }
      }
    }
  }

  Future<void> _pull() async {
    while (true) {
      final r = (await _store.http.request('POST', '/sync/pull', body: {'collections': collections, 'checkpoint': {'seq': _checkpoint}, 'limit': 500})) as Map;
      final resync = ((r['resync'] as List?) ?? const []).cast<String>();
      if (resync.isNotEmpty) {
        for (final c in resync) {
          for (final id in _col(c).keys.toList()) {
            if (!_outbox.containsKey('$c/$id')) await _remove(c, id);
          }
        }
        _checkpoint = 0;
        continue;
      }
      for (final raw in (r['documents'] as List)) {
        final d = (raw as Map).cast<String, Object?>();
        final c = '${d['collection']}';
        final id = '${d['id']}';
        final clock = ((d['clock'] as Map?) ?? const {}).cast<String, String>();
        clock.values.forEach(_hlc.observe);
        final pending = _outbox['$c/$id'];
        final data = (d['data'] as Map?)?.cast<String, Object?>();
        if (pending == null) {
          await _adopt(c, id, d['deleted'] == true ? null : {'data': data ?? {}, 'version': d['version'], 'createdAt': d['updatedAt'], 'updatedAt': d['updatedAt']}, (d['version'] as num).toInt(), clock);
          continue;
        }
        final local = _col(c)[id];
        if (local == null || pending.deleted || d['deleted'] == true || data == null) continue;
        final merged = <String, Object?>{};
        for (final k in {...data.keys, ...?local.data?.keys}) {
          final localWins = (local.clock[k] ?? '').compareTo(clock[k] ?? '') > 0;
          final src = localWins ? (local.data ?? const {}) : data;
          if (src.containsKey(k)) merged[k] = src[k];
        }
        local
          ..data = merged
          ..updatedAt = '${d['updatedAt']}';
        await _put(c, local);
      }
      _checkpoint = ((r['checkpoint'] as Map)['seq'] as num).toInt();
      await _storage.set('meta:checkpoint', _checkpoint);
      if (r['hasMore'] != true) return;
    }
  }

  Future<void> _refetch(String collection, String id) async {
    try {
      final s = await _store.collection(collection).doc(id).get();
      await _adopt(collection, id, s.exists ? {'data': s.json, 'version': s.version, 'createdAt': s.createdAt!.toIso8601String(), 'updatedAt': s.updatedAt!.toIso8601String()} : null, s.version);
    } catch (_) {}
  }

  Future<void> _adopt(String collection, String id, Map<String, Object?>? server, int version, [Map<String, String>? clock]) async {
    if (server == null) return _remove(collection, id);
    final prev = _col(collection)[id];
    await _put(
      collection,
      _LocalDoc(id, ((server['data'] as Map?) ?? const {}).cast<String, Object?>(), (server['version'] as num?)?.toInt() ?? version, clock ?? prev?.clock ?? {},
          prev?.createdAt ?? '${server['createdAt']}', '${server['updatedAt']}'),
    );
  }

  // ── local writes & reads ────────────────────────────────────────────────

  Future<void> _write(String collection, String id, ({JsonMap? data, List<String> touched}) Function(JsonMap? current) next) async {
    await _ready;
    final cur = _col(collection)[id];
    final r = next(cur?.data);
    final now = DateTime.now().toUtc().toIso8601String();
    final t = _hlc.now();
    final clock = {...?cur?.clock};
    if (r.data == null) {
      clock[r'$doc'] = t;
    } else {
      for (final k in r.touched) {
        clock[k] = t;
      }
    }
    await _put(collection, _LocalDoc(id, r.data, cur?.version ?? 0, clock, cur?.createdAt ?? now, now));
    final key = '$collection/$id';
    final prev = _outbox[key];
    final entry = _Outbox(collection, id, prev?.baseVersion ?? cur?.version ?? 0, r.data == null, r.data,
        r.data == null ? {r'$doc': t} : {...?prev?.clock, for (final k in r.touched) k: t}, ++_rev);
    _outbox[key] = entry;
    await _storage.set('out:$key', entry.toJson());
    _schedule(const Duration(milliseconds: 250));
  }

  Future<LocalSnapshot?> _read(String collection, String id) async {
    await _ready;
    final d = _col(collection)[id];
    return d == null || d.data == null ? null : _snap(collection, d);
  }

  Future<List<LocalSnapshot>> _query(String collection, JsonMap? filter, List<SortKey> sort, int? limit) async {
    await _ready;
    final rows = _col(collection).values.where((d) => d.data != null && matchesFilter(filter, d.id, d.data!)).toList();
    final cmp = comparator(sort);
    rows.sort((a, b) => cmp((id: a.id, data: a.data!, createdAt: a.createdAt, updatedAt: a.updatedAt), (id: b.id, data: b.data!, createdAt: b.createdAt, updatedAt: b.updatedAt)));
    return rows.take(limit ?? rows.length).map((d) => _snap(collection, d)).toList();
  }

  LocalSnapshot _snap(String collection, _LocalDoc d) =>
      LocalSnapshot(d.id, d.data, d.version, _outbox.containsKey('$collection/${d.id}'), DateTime.parse(d.createdAt), DateTime.parse(d.updatedAt));

  Future<void> _put(String collection, _LocalDoc doc) async {
    _col(collection)[doc.id] = doc;
    await _storage.set('doc:$collection/${doc.id}', doc.toJson());
    _changes.add(collection);
  }

  Future<void> _remove(String collection, String id) async {
    if (_col(collection).remove(id) == null) return;
    await _storage.delete('doc:$collection/$id');
    _changes.add(collection);
  }

  Future<void> _dropOutbox(String key) async {
    _outbox.remove(key);
    await _storage.delete('out:$key');
    _changes.add(key.substring(0, key.indexOf('/')));
  }

  void _setStatus(SyncStatus s) {
    status = s;
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }

  Stream<T> _watch<T>(String collection, Future<T> Function() read, String Function(T) signature) {
    late StreamController<T> ctl;
    StreamSubscription<String>? sub;
    var last = '\u0000';
    Future<void> run() async {
      final v = await read();
      final sig = signature(v);
      if (sig != last && !ctl.isClosed) {
        last = sig;
        ctl.add(v);
      }
    }

    ctl = StreamController<T>(
      onListen: () {
        sub = _changes.stream.where((c) => c == collection).listen((_) => run());
        run();
      },
      onCancel: () => sub?.cancel(),
    );
    return ctl.stream;
  }
}

// ── local refs & queries ──────────────────────────────────────────────────

class LocalQuery {
  LocalQuery._(this._engine, this.collection, this._filter, this._sort, this._limit);
  final OfflineStore _engine;
  final String collection;
  final JsonMap? _filter;
  final List<SortKey> _sort;
  final int? _limit;

  LocalQuery where(String field, {Object? isEqualTo, Object? isNotEqualTo, Object? isLessThan, Object? isLessThanOrEqualTo, Object? isGreaterThan, Object? isGreaterThanOrEqualTo, List<Object?>? whereIn, List<Object?>? whereNotIn, Object? arrayContains, List<Object?>? arrayContainsAny, bool? exists, bool? isNull}) =>
      whereFilter(Filter(field, isEqualTo: isEqualTo, isNotEqualTo: isNotEqualTo, isLessThan: isLessThan, isLessThanOrEqualTo: isLessThanOrEqualTo, isGreaterThan: isGreaterThan, isGreaterThanOrEqualTo: isGreaterThanOrEqualTo, whereIn: whereIn, whereNotIn: whereNotIn, arrayContains: arrayContains, arrayContainsAny: arrayContainsAny, exists: exists, isNull: isNull));

  LocalQuery whereFilter(Filter f) => LocalQuery._(_engine, collection, _filter == null ? f.json : {r'$and': [_filter, f.json]}, _sort, _limit);
  LocalQuery orderBy(String field, {bool descending = false}) => LocalQuery._(_engine, collection, _filter, [..._sort, SortKey(field == 'id' ? r'$id' : field, descending)], _limit);
  LocalQuery limit(int n) => LocalQuery._(_engine, collection, _filter, _sort, n);

  /// Evaluated on the device — instant, works offline.
  Future<List<LocalSnapshot>> get() => _engine._query(collection, _filter, _sort, _limit);

  /// Re-emits on every local change (your writes and synced remote ones).
  Stream<List<LocalSnapshot>> snapshots() => _engine._watch(collection, get, (docs) => jsonEncode([for (final d in docs) [d.id, d.version, d.hasPendingWrites, d.data()]]));
}

class LocalCollection extends LocalQuery {
  LocalCollection._(super.engine, super.collection, super.filter, super.sort, super.limit) : super._();

  LocalDocumentRef doc([String? id]) => LocalDocumentRef._(_engine, collection, id ?? newDocId());

  /// Create locally with a time-sortable id; replicated in the background.
  Future<LocalDocumentRef> add(JsonMap data) async {
    final ref = doc();
    await ref.set(data);
    return ref;
  }
}

class LocalDocumentRef {
  LocalDocumentRef._(this._engine, this.collection, this.id);
  final OfflineStore _engine;
  final String collection;
  final String id;

  Future<LocalSnapshot?> get() => _engine._read(collection, id);

  Future<void> set(JsonMap data, {bool merge = false}) => _engine._write(collection, id, (cur) {
        final next = merge && cur != null ? (deepMerge(cur, data) as Map).cast<String, Object?>() : jsonClone(data);
        final touched = {...?cur?.keys, ...next.keys}.where((k) => !deepEqual(cur?[k], next[k])).toList();
        return (data: next, touched: touched);
      });

  /// [FieldValue]s work offline (applied locally; the server merges the
  /// resulting fields by clock).
  Future<void> update(Map<String, Object?> data) => _engine._write(collection, id, (cur) {
        if (cur == null) throw DocStoreException("Document '$collection/$id' does not exist locally", 'not_found', 404);
        final r = applyUpdate(cur, toUpdateSpec(data));
        return (data: r.data, touched: r.touched);
      });

  Future<void> delete() => _engine._write(collection, id, (_) => (data: null, touched: const <String>[]));

  Stream<LocalSnapshot?> snapshots() =>
      _engine._watch(collection, get, (s) => s == null ? 'null' : jsonEncode([s.version, s.hasPendingWrites, s.data()]));
}
