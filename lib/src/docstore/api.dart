import 'dart:async';
import 'dart:math';

import 'client.dart';
import 'core.dart';
import 'live.dart';

// ── field values ──────────────────────────────────────────────────────────

/// Atomic, server-side field updates (applied under a row lock — concurrent
/// increments never lose). Use as values in [DocumentReference.update].
class FieldValue {
  const FieldValue._(this._kind, [this._value, this._slice]);
  final String _kind;
  final Object? _value;
  final int? _slice;

  static FieldValue increment(num n) => FieldValue._('inc', n);
  static FieldValue multiply(num n) => FieldValue._('mul', n);
  static FieldValue minimum(Object v) => FieldValue._('min', v);
  static FieldValue maximum(Object v) => FieldValue._('max', v);
  static FieldValue arrayUnion(List<Object?> values) => FieldValue._('union', values);
  static FieldValue arrayRemove(List<Object?> values) => FieldValue._('remove', values);

  /// Append (duplicates allowed); [keepLast] caps the array (a rolling log).
  static FieldValue arrayPush(List<Object?> values, {int? keepLast}) => FieldValue._('push', values, keepLast == null ? null : -keepLast);
  static FieldValue serverTimestamp() => const FieldValue._('serverTime');
  static FieldValue delete() => const FieldValue._('delete');
  static FieldValue merge(JsonMap value) => FieldValue._('merge', value);
}

/// `{'views': FieldValue.increment(1), 'a.b': 2}` → server update operators.
/// A map already using `$` operators passes through.
JsonMap toUpdateSpec(Map<String, Object?> update) {
  if (isOperatorUpdate(update)) return update;
  final spec = <String, Object?>{};
  void put(String op, String f, Object? v) => ((spec[op] ??= <String, Object?>{}) as Map)[f] = v;
  void list(String op, String f) => ((spec[op] ??= <String>[]) as List).add(f);
  update.forEach((field, v) {
    if (v is! FieldValue) return put(r'$set', field, v);
    switch (v._kind) {
      case 'inc':
        put(r'$inc', field, v._value);
      case 'mul':
        put(r'$mul', field, v._value);
      case 'min':
        put(r'$min', field, v._value);
      case 'max':
        put(r'$max', field, v._value);
      case 'union':
        put(r'$addToSet', field, {r'$each': v._value});
      case 'remove':
        put(r'$pull', field, {r'$in': v._value});
      case 'push':
        put(r'$push', field, {r'$each': v._value, if (v._slice != null) r'$slice': v._slice});
      case 'serverTime':
        list(r'$serverTime', field);
      case 'delete':
        list(r'$unset', field);
      case 'merge':
        put(r'$merge', field, v._value);
    }
  });
  return spec;
}

// ── filters ───────────────────────────────────────────────────────────────

/// A query condition, composable with [Filter.or] / [Filter.and].
class Filter {
  /// One field. Name the comparison with exactly the arguments you need:
  /// `Filter('total', isGreaterThanOrEqualTo: 100)`.
  factory Filter(
    String field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    List<Object?>? whereIn,
    List<Object?>? whereNotIn,
    Object? arrayContains,
    List<Object?>? arrayContainsAny,
    List<Object?>? arrayContainsAll,
    String? startsWith,
    String? endsWith,
    String? matches,
    bool? exists,
    bool? isNull,
  }) {
    final ops = <String, Object?>{
      r'$eq': ?isEqualTo,
      r'$ne': ?isNotEqualTo,
      r'$lt': ?isLessThan,
      r'$lte': ?isLessThanOrEqualTo,
      r'$gt': ?isGreaterThan,
      r'$gte': ?isGreaterThanOrEqualTo,
      r'$in': ?whereIn,
      r'$nin': ?whereNotIn,
      r'$contains': ?arrayContains,
      r'$containsAny': ?arrayContainsAny,
      r'$containsAll': ?arrayContainsAll,
      r'$startsWith': ?startsWith,
      r'$endsWith': ?endsWith,
      r'$regex': ?matches,
      r'$exists': ?exists,
      if (isNull != null) r'$exists': !isNull,
    };
    if (ops.isEmpty) throw ArgumentError('Filter("$field") needs a condition (isEqualTo, isGreaterThan, …)');
    return Filter.raw({field == 'id' ? r'$id' : field: ops});
  }

  /// A raw JSON filter, exactly as the server accepts it.
  const Filter.raw(this.json);
  factory Filter.or(List<Filter> filters) => Filter.raw({r'$or': filters.map((f) => f.json).toList()});
  factory Filter.and(List<Filter> filters) => Filter.raw({r'$and': filters.map((f) => f.json).toList()});
  factory Filter.not(Filter filter) => Filter.raw({r'$not': filter.json});

  /// Match through a relation: `Filter.related('author', Filter('verified', isEqualTo: true))`.
  factory Filter.related(String relation, Filter filter) => Filter.raw({relation: {r'$rel': filter.json}});

  final JsonMap json;
}

// ── snapshots ─────────────────────────────────────────────────────────────

class DocumentSnapshot<T> {
  DocumentSnapshot(this.reference, this._raw, this._fromJson);
  final DocumentReference<T> reference;
  final JsonMap? _raw;
  final T Function(JsonMap json, String id) _fromJson;

  String get id => reference.id;
  bool get exists => _raw != null;
  T? data() => _raw == null ? null : _fromJson((_raw['data'] as Map).cast<String, Object?>(), id);

  /// The raw JSON data.
  JsonMap? get json => _raw == null ? null : (_raw['data'] as Map).cast<String, Object?>();
  Object? get(String path) => getPath(json, path);
  int get version => (_raw?['version'] as num?)?.toInt() ?? 0;
  DateTime? get createdAt => _raw == null ? null : DateTime.parse('${_raw['createdAt']}');
  DateTime? get updatedAt => _raw == null ? null : DateTime.parse('${_raw['updatedAt']}');

  /// Related documents requested with `expand`.
  Map<String, Object?> get expand => ((_raw?['expand'] as Map?) ?? const {}).cast<String, Object?>();
}

class QuerySnapshot<T> {
  QuerySnapshot(this.docs, {this.nextCursor, this.hasMore = false, this.total, this.docChanges = const []});
  final List<DocumentSnapshot<T>> docs;

  /// Pass to [Query.startAfter] for the next page.
  final String? nextCursor;
  final bool hasMore;

  /// Set when the query used [Query.withCount].
  final int? total;

  /// Live snapshots only: what changed since the previous one.
  final List<DocumentChange<T>> docChanges;
  int get size => docs.length;
  bool get isEmpty => docs.isEmpty;
}

enum DocumentChangeType { added, modified, removed }

class DocumentChange<T> {
  DocumentChange(this.type, this.doc, this.newIndex, this.oldIndex);
  final DocumentChangeType type;
  final DocumentSnapshot<T> doc;
  final int newIndex;
  final int oldIndex;
}

/// An aggregation for [Query.aggregate] / [Query.aggregateSnapshots].
class AggregateField {
  const AggregateField._(this.op, [this.field]);
  final String op;
  final String? field;
  static const AggregateField count = AggregateField._('count');
  static AggregateField countDistinct(String field) => AggregateField._('countDistinct', field);
  static AggregateField sum(String field) => AggregateField._('sum', field);
  static AggregateField average(String field) => AggregateField._('avg', field);
  static AggregateField min(String field) => AggregateField._('min', field);
  static AggregateField max(String field) => AggregateField._('max', field);
  Map<String, Object?> toJson() => {'op': op, if (field != null) 'field': field};
}

class AggregateGroup {
  AggregateGroup(this.key, this.values);
  final Map<String, Object?> key;
  final Map<String, num?> values;
}

List<AggregateGroup> _groups(Object? result) => (((result as Map?)?['groups'] as List?) ?? const [])
    .map((g) => AggregateGroup(((g as Map)['key'] as Map).cast<String, Object?>(), (g['values'] as Map).map((k, v) => MapEntry('$k', v as num?))))
    .toList();

// ── query ─────────────────────────────────────────────────────────────────

class Query<T> {
  Query._(this._store, this.path, this._body, this._fromJson, this._toJson);

  final DocStore _store;
  final String path;
  final JsonMap _body;
  final T Function(JsonMap json, String id) _fromJson;
  final JsonMap Function(T value) _toJson;

  Query<T> _with(JsonMap patch) => Query<T>._(_store, path, {..._body, ...patch}, _fromJson, _toJson);

  /// Add a condition (ANDed with the existing ones).
  Query<T> where(
    String field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    List<Object?>? whereIn,
    List<Object?>? whereNotIn,
    Object? arrayContains,
    List<Object?>? arrayContainsAny,
    List<Object?>? arrayContainsAll,
    String? startsWith,
    String? endsWith,
    String? matches,
    bool? exists,
    bool? isNull,
  }) =>
      whereFilter(Filter(field,
          isEqualTo: isEqualTo,
          isNotEqualTo: isNotEqualTo,
          isLessThan: isLessThan,
          isLessThanOrEqualTo: isLessThanOrEqualTo,
          isGreaterThan: isGreaterThan,
          isGreaterThanOrEqualTo: isGreaterThanOrEqualTo,
          whereIn: whereIn,
          whereNotIn: whereNotIn,
          arrayContains: arrayContains,
          arrayContainsAny: arrayContainsAny,
          arrayContainsAll: arrayContainsAll,
          startsWith: startsWith,
          endsWith: endsWith,
          matches: matches,
          exists: exists,
          isNull: isNull));

  /// Add a composed filter (`Filter.or([...])`, `Filter.related(...)`, `Filter.raw(...)`).
  Query<T> whereFilter(Filter filter) {
    final cur = _body['filter'] as JsonMap?;
    return _with({'filter': cur == null ? filter.json : {r'$and': [cur, filter.json]}});
  }

  Query<T> orderBy(String field, {bool descending = false}) =>
      _with({'sort': [...((_body['sort'] as List?) ?? const []), SortKey(field == 'id' ? r'$id' : field, descending).toJson()]});
  Query<T> limit(int n) => _with({'limit': n});

  /// Keyset pagination: the [QuerySnapshot.nextCursor] of the previous page.
  Query<T> startAfter(String cursor) => _with({'cursor': cursor});
  Query<T> select(List<String> fields) => _with({'select': fields});

  /// Inline related documents (`expand(['author', 'author.company'])`).
  Query<T> expand(List<String> relations) => _with({'expand': [...((_body['expand'] as List?) ?? const []), ...relations]});

  /// Full-text search over the collection's search fields.
  Query<T> search(String text) => _with({'search': text});

  /// Time travel: the collection as it was at [when].
  Query<T> asOf(DateTime when) => _with({'asOf': when.toUtc().toIso8601String()});
  Query<T> withCount() => _with({'count': true});

  Map<String, Object?> toJson() => Map.of(_body);

  CollectionReference<T> get _col => CollectionReference<T>._(_store, path, _fromJson, _toJson);

  Future<QuerySnapshot<T>> get() async {
    final r = (await _store.http.request('POST', '/collections/${Uri.encodeComponent(path)}/query', body: _body)) as Map;
    final docs = ((r['items'] as List?) ?? const []).map((d) {
      final m = (d as Map).cast<String, Object?>();
      return DocumentSnapshot<T>(_col.doc('${m['id']}'), m, _fromJson);
    }).toList();
    return QuerySnapshot<T>(docs, nextCursor: r['nextCursor'] as String?, hasMore: r['hasMore'] == true, total: (r['total'] as num?)?.toInt());
  }

  /// Every match, page by page.
  Stream<DocumentSnapshot<T>> all({int pageSize = 200}) async* {
    var q = limit(pageSize);
    while (true) {
      final page = await q.get();
      yield* Stream.fromIterable(page.docs);
      if (page.nextCursor == null) return;
      q = q.startAfter(page.nextCursor!);
    }
  }

  Future<int> count() async => ((await aggregate({'n': AggregateField.count})).firstOrNull?.values['n'] ?? 0).toInt();

  Future<List<AggregateGroup>> aggregate(Map<String, AggregateField> aggregations, {List<String>? groupBy, int? limit}) async {
    final r = await _store.http.request('POST', '/collections/${Uri.encodeComponent(path)}/aggregate', body: {
      if (_body['filter'] != null) 'filter': _body['filter'],
      if (_body['search'] != null) 'search': _body['search'],
      if (_body['asOf'] != null) 'asOf': _body['asOf'],
      'aggregations': aggregations.map((k, v) => MapEntry(k, v.toJson())),
      'groupBy': ?groupBy,
      'limit': ?limit,
    });
    return _groups(r);
  }

  /// Live results — the snapshot now, then one per change, rules applied server-side.
  Stream<QuerySnapshot<T>> snapshots() {
    if (_body['asOf'] != null) throw DocStoreException('A time-travel (asOf) query cannot be live', 'bad_request', 400);
    late StreamController<QuerySnapshot<T>> ctl;
    void Function()? stop;
    var docs = <DocumentSnapshot<T>>[];
    DocumentSnapshot<T> snap(Map<String, Object?> m) => DocumentSnapshot<T>(_col.doc('${m['id']}'), m, _fromJson);
    ctl = StreamController<QuerySnapshot<T>>(
      onListen: () {
        stop = _store.live.subscribe(
          {'collection': path, 'kind': 'query', 'filter': _body['filter'], 'sort': _body['sort'], 'limit': _body['limit'], 'search': _body['search'], 'select': _body['select']},
          LiveHandlers(
            onSnapshot: (ack) {
              docs = ((ack['items'] as List?) ?? const []).map((d) => snap((d as Map).cast<String, Object?>())).toList();
              ctl.add(QuerySnapshot<T>(List.of(docs), hasMore: ack['hasMore'] == true, docChanges: [for (var i = 0; i < docs.length; i++) DocumentChange(DocumentChangeType.added, docs[i], i, -1)]));
            },
            onChanges: (changes, hasMore) {
              final out = <DocumentChange<T>>[];
              for (final c in changes) {
                if (c['type'] == 'removed') {
                  final i = docs.indexWhere((d) => d.id == c['id']);
                  if (i >= 0) out.add(DocumentChange(DocumentChangeType.removed, docs.removeAt(i), -1, (c['oldIndex'] as num).toInt()));
                  continue;
                }
                final m = (c['doc'] as Map).cast<String, Object?>();
                docs.removeWhere((d) => d.id == m['id']);
                final d = snap(m);
                final index = min((c['index'] as num).toInt(), docs.length);
                docs.insert(index, d);
                out.add(DocumentChange(c['type'] == 'added' ? DocumentChangeType.added : DocumentChangeType.modified, d, index, (c['oldIndex'] as num?)?.toInt() ?? -1));
              }
              ctl.add(QuerySnapshot<T>(List.of(docs), hasMore: hasMore, docChanges: out));
            },
            onError: (code, message) => ctl.addError(DocStoreException(message, code, 0)),
          ),
        );
      },
      onCancel: () => stop?.call(),
    );
    return ctl.stream;
  }

  /// A live aggregate that re-computes as documents change.
  Stream<List<AggregateGroup>> aggregateSnapshots(Map<String, AggregateField> aggregations, {List<String>? groupBy}) {
    late StreamController<List<AggregateGroup>> ctl;
    void Function()? stop;
    ctl = StreamController(
      onListen: () {
        stop = _store.live.subscribe(
          {'collection': path, 'kind': 'aggregate', 'filter': _body['filter'], 'search': _body['search'], 'aggregations': aggregations.map((k, v) => MapEntry(k, v.toJson())), 'groupBy': ?groupBy},
          LiveHandlers(
            onSnapshot: (ack) => ctl.add(_groups(ack['result'])),
            onAggregate: (r) => ctl.add(_groups(r)),
            onError: (code, message) => ctl.addError(DocStoreException(message, code, 0)),
          ),
        );
      },
      onCancel: () => stop?.call(),
    );
    return ctl.stream;
  }
}

// ── references ────────────────────────────────────────────────────────────

class CollectionReference<T> extends Query<T> {
  CollectionReference._(DocStore store, String path, T Function(JsonMap, String) fromJson, JsonMap Function(T) toJson) : super._(store, path, const {}, fromJson, toJson);

  DocumentReference<T> doc([String? id]) => DocumentReference<T>._(_store, path, id ?? newDocId(), _fromJson, _toJson);

  /// Create with a generated, time-sortable id.
  Future<DocumentSnapshot<T>> add(T data, {String? id}) async {
    final r = (await _store.http.request('POST', '/collections/${Uri.encodeComponent(path)}/docs', body: {'id': ?id, 'data': _toJson(data)})) as Map;
    return DocumentSnapshot<T>(doc('${r['id']}'), (r['doc'] as Map?)?.cast<String, Object?>(), _fromJson);
  }

  /// Typed models: `db.collection('posts').withConverter(fromJson: Post.fromJson, toJson: (p) => p.toJson())`.
  CollectionReference<R> withConverter<R>({required R Function(JsonMap json, String id) fromJson, required JsonMap Function(R value) toJson}) =>
      CollectionReference<R>._(_store, path, fromJson, toJson);
}

class DocumentReference<T> {
  DocumentReference._(this._store, this.collection, this.id, this._fromJson, this._toJson);
  final DocStore _store;
  final String collection;
  final String id;
  final T Function(JsonMap, String) _fromJson;
  final JsonMap Function(T) _toJson;

  String get path => '$collection/$id';
  String get _url => '/collections/${Uri.encodeComponent(collection)}/docs/${Uri.encodeComponent(id)}';

  DocumentSnapshot<T> _snap(Object? raw) => DocumentSnapshot<T>(this, (raw as Map?)?.cast<String, Object?>(), _fromJson);

  /// Read; a missing document returns `exists == false`. [asOf] reads it as it was then.
  Future<DocumentSnapshot<T>> get({List<String>? expand, List<String>? select, DateTime? asOf}) async {
    try {
      return _snap(await _store.http.request('GET', _url, query: {
        'expand': expand?.join(','),
        'select': select?.join(','),
        'asOf': asOf?.toUtc().toIso8601String(),
      }));
    } on DocStoreException catch (e) {
      if (e.code == 'not_found') return _snap(null);
      rethrow;
    }
  }

  /// Create or replace (deep-merge with [merge]). [ifVersion] guards against
  /// overwriting a change you haven't seen (0 = must not exist).
  Future<DocumentSnapshot<T>> set(T data, {bool merge = false, int? ifVersion}) async {
    final r = (await _store.http.request('PUT', _url, body: {'data': _toJson(data), if (merge) 'merge': true, if (ifVersion != null) 'precondition': {'version': ifVersion}})) as Map;
    return _snap(r['doc']);
  }

  /// Partial update: `{'views': FieldValue.increment(1), 'profile.name': 'Ana'}`.
  Future<DocumentSnapshot<T>> update(Map<String, Object?> data, {int? ifVersion, bool upsert = false}) async {
    final r = (await _store.http.request('PATCH', _url, body: {'update': toUpdateSpec(data), if (upsert) 'upsert': true, if (ifVersion != null) 'precondition': {'version': ifVersion}})) as Map;
    return _snap(r['doc']);
  }

  Future<void> delete({int? ifVersion}) async {
    await _store.http.request('DELETE', _url, query: {'ifVersion': ifVersion?.toString()});
  }

  /// Every version, newest first, with the fields each one changed.
  Future<List<DocumentVersion<T>>> history({int? limit, int? beforeVersion}) async {
    final r = (await _store.http.request('GET', '$_url/history', query: {'limit': limit?.toString(), 'beforeVersion': beforeVersion?.toString()})) as Map;
    return ((r['versions'] as List?) ?? const []).map((v) {
      final m = (v as Map).cast<String, Object?>();
      final data = (m['data'] as Map?)?.cast<String, Object?>();
      return DocumentVersion<T>((m['version'] as num).toInt(), '${m['op']}', DateTime.parse('${m['at']}'), m['actor'] as String?, m['deleted'] == true, data == null ? null : _fromJson(data, id), ((m['changedFields'] as List?) ?? const []).cast<String>());
    }).toList();
  }

  /// Back to an earlier version — written as a NEW version, so it is undoable.
  Future<DocumentSnapshot<T>> restore(int version) async {
    final r = (await _store.http.request('POST', '$_url/restore', body: {'version': version})) as Map;
    return _snap(r['doc']);
  }

  /// Live document (`exists == false` once deleted).
  Stream<DocumentSnapshot<T>> snapshots() {
    late StreamController<DocumentSnapshot<T>> ctl;
    void Function()? stop;
    ctl = StreamController(
      onListen: () {
        stop = _store.live.subscribe(
          {'collection': collection, 'kind': 'doc', 'id': id},
          LiveHandlers(
            onSnapshot: (ack) => ctl.add(_snap(ack['doc'])),
            onDoc: (d) => ctl.add(_snap(d)),
            onError: (code, message) => ctl.addError(DocStoreException(message, code, 0)),
          ),
        );
      },
      onCancel: () => stop?.call(),
    );
    return ctl.stream;
  }
}

class DocumentVersion<T> {
  DocumentVersion(this.version, this.op, this.at, this.actor, this.deleted, this.data, this.changedFields);
  final int version;
  final String op;
  final DateTime at;
  final String? actor;
  final bool deleted;
  final T? data;
  final List<String> changedFields;
}

// ── batches & transactions ────────────────────────────────────────────────

/// Up to 500 writes committed atomically: all apply, or none do.
class WriteBatch {
  WriteBatch._(this._store);
  final DocStore _store;
  final List<JsonMap> _ops = [];

  void create<T>(DocumentReference<T> ref, T data) => _ops.add({'type': 'create', 'collection': ref.collection, 'id': ref.id, 'data': ref._toJson(data)});
  void set<T>(DocumentReference<T> ref, T data, {bool merge = false, int? ifVersion}) =>
      _ops.add({'type': 'set', 'collection': ref.collection, 'id': ref.id, 'data': ref._toJson(data), if (merge) 'merge': true, if (ifVersion != null) 'precondition': {'version': ifVersion}});
  void update(DocumentReference<Object?> ref, Map<String, Object?> data, {int? ifVersion}) =>
      _ops.add({'type': 'update', 'collection': ref.collection, 'id': ref.id, 'update': toUpdateSpec(data), if (ifVersion != null) 'precondition': {'version': ifVersion}});
  void delete(DocumentReference<Object?> ref, {int? ifVersion}) =>
      _ops.add({'type': 'delete', 'collection': ref.collection, 'id': ref.id, if (ifVersion != null) 'precondition': {'version': ifVersion}});

  Future<void> commit() async {
    if (_ops.isEmpty) return;
    await _store.http.request('POST', '/commit', body: {'operations': _ops});
  }
}

/// Read-modify-write: reads record versions, writes are guarded by them, and
/// [DocStore.runTransaction] retries when another write got there first.
class Transaction extends WriteBatch {
  Transaction._(super.store) : super._();
  final _seen = <String, int>{};

  Future<DocumentSnapshot<T>> get<T>(DocumentReference<T> ref) async {
    final s = await ref.get();
    _seen[ref.path] = s.version;
    return s;
  }

  @override
  Future<void> commit() async {
    for (final op in _ops) {
      final v = _seen['${op['collection']}/${op['id']}'];
      if (v != null && op['precondition'] == null) op['precondition'] = {'version': v};
      if (op['type'] == 'create' && op['precondition'] == null) op['precondition'] = {'exists': false};
    }
    return super.commit();
  }
}

// ── the client ────────────────────────────────────────────────────────────

class DocStore {
  DocStore(this.http, this._liveFactory);

  final DocStoreHttp http;
  final DocStoreLive Function() _liveFactory;
  DocStoreLive? _live;

  /// The shared live connection (opened on first use).
  DocStoreLive get live => _live ??= _liveFactory();

  static JsonMap _id(JsonMap json, String id) => json;

  CollectionReference<JsonMap> collection(String name) => CollectionReference<JsonMap>._(this, name, _id, (v) => v);

  /// `doc('posts/p1')`.
  DocumentReference<JsonMap> doc(String path) {
    final i = path.indexOf('/');
    if (i <= 0) throw ArgumentError("'$path' is not a <collection>/<id> path");
    return collection(path.substring(0, i)).doc(path.substring(i + 1));
  }

  WriteBatch batch() => WriteBatch._(this);

  Future<R> runTransaction<R>(Future<R> Function(Transaction tx) fn, {int maxAttempts = 5}) async {
    final rnd = Random();
    for (var attempt = 1;; attempt++) {
      final tx = Transaction._(this);
      final result = await fn(tx);
      try {
        await tx.commit();
        return result;
      } on DocStoreException catch (e) {
        if (!e.isPreconditionFailed || attempt >= maxAttempts) rethrow;
        await Future<void>.delayed(Duration(milliseconds: (min(1000, 25 * pow(2, attempt)) * (0.5 + rnd.nextDouble())).round()));
      }
    }
  }

  /// Server-side (service key): deploy a collection's configuration as code.
  Future<Object?> deployCollection(String name, JsonMap config) => http.request('PUT', '/collections/${Uri.encodeComponent(name)}', body: config);

  void close() {
    _live?.close();
    _live = null;
  }
}
