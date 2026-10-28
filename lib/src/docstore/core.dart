// The pure core shared by the remote client and the offline engine. These
// MIRROR the server (`modules/databases/shared/expression/values.ts`,
// `docstore/domain/update-ops.ts`, `docstore/domain/sync.ts`) and the JS SDK,
// so a query evaluated on the local cache returns what the server would.

import 'dart:convert';
import 'dart:math';

typedef JsonMap = Map<String, Object?>;

/// Thrown when a filter needs the server (`$rel`, `$search`, `$expr`) but is
/// evaluated against the offline cache.
class LocalQueryException implements Exception {
  LocalQueryException(this.message);
  final String message;
  @override
  String toString() => 'LocalQueryException: $message';
}

// ── values ────────────────────────────────────────────────────────────────

String typeOf(Object? v) {
  if (v == null) return 'null';
  if (v is List) return 'array';
  if (v is bool) return 'boolean';
  if (v is num) return 'number';
  if (v is String) return 'string';
  return 'object';
}

bool deepEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  final ta = typeOf(a);
  if (ta != typeOf(b)) return false;
  switch (ta) {
    case 'null':
      return true;
    case 'number':
      return (a as num) == (b as num);
    case 'array':
      final x = a as List;
      final y = b as List;
      if (x.length != y.length) return false;
      for (var i = 0; i < x.length; i++) {
        if (!deepEqual(x[i], y[i])) return false;
      }
      return true;
    case 'object':
      final x = (a as Map).cast<String, Object?>();
      final y = (b as Map).cast<String, Object?>();
      if (x.length != y.length) return false;
      for (final k in x.keys) {
        if (!y.containsKey(k) || !deepEqual(x[k], y[k])) return false;
      }
      return true;
    default:
      return a == b;
  }
}

/// Type-bracketed: `age > 18` is false (not an error) for a string `age`.
int? compareBracketed(Object? a, Object? b) {
  final ta = typeOf(a);
  if (ta != typeOf(b)) return null;
  switch (ta) {
    case 'number':
      return (a as num).compareTo(b as num);
    case 'string':
      return (a as String).compareTo(b as String);
    case 'boolean':
      return (a == true ? 1 : 0) - (b == true ? 1 : 0);
  }
  return null;
}

const _rank = {'null': 0, 'string': 1, 'number': 2, 'boolean': 3, 'array': 4, 'object': 5};

/// Total order for sorting — Postgres jsonb order: null < string < number < boolean < array < object.
int compareTotal(Object? a, Object? b) {
  final ta = typeOf(a);
  final tb = typeOf(b);
  if (ta != tb) return _rank[ta]! - _rank[tb]!;
  if (ta == 'array') {
    final x = a as List;
    final y = b as List;
    if (x.length != y.length) return x.length - y.length;
    for (var i = 0; i < x.length; i++) {
      final c = compareTotal(x[i], y[i]);
      if (c != 0) return c;
    }
    return 0;
  }
  if (ta == 'object') return jsonEncode(a).compareTo(jsonEncode(b));
  return compareBracketed(a, b) ?? 0;
}

Object? getPath(Object? v, String path) {
  Object? cur = v;
  for (final s in path.split('.')) {
    if (cur == null) return null;
    if (cur is List) {
      final i = int.tryParse(s);
      cur = i != null && i >= 0 && i < cur.length ? cur[i] : null;
    } else if (cur is Map) {
      cur = cur[s];
    } else {
      return null;
    }
  }
  return cur;
}

/// Deep copy through JSON (documents are JSON).
T jsonClone<T>(T v) => v == null ? v : jsonDecode(jsonEncode(v)) as T;

// ── filter matcher ────────────────────────────────────────────────────────

bool _inOp(Object? l, Object? r) {
  if (r is List) return r.any((v) => deepEqual(v, l));
  if (r is Map) return l is String && r.containsKey(l);
  if (r is String && l is String) return r.contains(l);
  return false;
}

/// Evaluate a JSON filter against `{id, data}` exactly as the server would.
bool matchesFilter(JsonMap? filter, String id, JsonMap data) {
  if (filter == null) return true;
  for (final entry in filter.entries) {
    final key = entry.key;
    final cond = entry.value;
    if (key == r'$and' || key == r'$or' || key == r'$nor') {
      final subs = (cond as List).map((f) => matchesFilter((f as Map).cast<String, Object?>(), id, data)).toList();
      final ok = key == r'$and' ? subs.every((x) => x) : key == r'$or' ? subs.any((x) => x) : !subs.any((x) => x);
      if (!ok) return false;
      continue;
    }
    if (key == r'$not') {
      if (matchesFilter((cond as Map).cast<String, Object?>(), id, data)) return false;
      continue;
    }
    if (key == r'$search' || key == r'$expr') {
      throw LocalQueryException('$key needs the server — not available on the offline cache');
    }
    final value = key == r'$id' ? id : getPath(data, key);
    if (!_fieldMatches(key, value, cond)) return false;
  }
  return true;
}

bool _isOperatorObject(Object? v) => v is Map && v.isNotEmpty && v.keys.every((k) => '$k'.startsWith(r'$'));

bool _fieldMatches(String key, Object? value, Object? cond) {
  if (!_isOperatorObject(cond)) return deepEqual(value, cond);
  for (final e in (cond as Map).entries) {
    final op = e.key as String;
    final arg = e.value;
    bool cmp(bool Function(int) f) {
      final c = compareBracketed(value, arg);
      return c != null && f(c);
    }

    bool ok;
    switch (op) {
      case r'$eq':
        ok = deepEqual(value, arg);
      case r'$ne':
        ok = !deepEqual(value, arg);
      case r'$gt':
        ok = cmp((c) => c > 0);
      case r'$gte':
        ok = cmp((c) => c >= 0);
      case r'$lt':
        ok = cmp((c) => c < 0);
      case r'$lte':
        ok = cmp((c) => c <= 0);
      case r'$in':
        ok = _inOp(value, arg);
      case r'$nin':
        ok = !_inOp(value, arg);
      case r'$between':
        final range = arg as List;
        final lo = compareBracketed(value, range[0]);
        final hi = compareBracketed(value, range[1]);
        ok = lo != null && hi != null && lo >= 0 && hi <= 0;
      case r'$exists':
        ok = arg == true ? value != null : value == null;
      case r'$contains':
        ok = _inOp(arg, value);
      case r'$containsAny':
        ok = value is List && (arg as List).any((x) => _inOp(x, value));
      case r'$containsAll':
        ok = value is List && (arg as List).every((x) => _inOp(x, value));
      case r'$startsWith':
        ok = value is String && value.startsWith(arg as String);
      case r'$endsWith':
        ok = value is String && value.endsWith(arg as String);
      case r'$regex':
        final pattern = arg is List ? arg[0] as String : arg as String;
        final flags = arg is List && arg.length > 1 ? arg[1] as String : '';
        ok = value is String && RegExp(pattern, caseSensitive: !flags.contains('i'), multiLine: flags.contains('m'), dotAll: flags.contains('s')).hasMatch(value);
      case r'$size':
        final n = value is String ? value.length : value is List ? value.length : value is Map ? value.length : 0;
        ok = n == arg;
      case r'$type':
        ok = typeOf(value) == arg;
      case r'$not':
        ok = !_fieldMatches(key, value, arg);
      case r'$rel':
        throw LocalQueryException("\$rel on '$key' needs the server — not available on the offline cache");
      default:
        throw LocalQueryException("unknown operator '$op' on '$key'");
    }
    if (!ok) return false;
  }
  return true;
}

class SortKey {
  const SortKey(this.field, [this.descending = false]);
  final String field;
  final bool descending;
  Map<String, Object?> toJson() => {'field': field, 'dir': descending ? 'desc' : 'asc'};
}

/// Comparator for local sorting with the server's `$id` tie-break.
int Function(({String id, JsonMap data, String createdAt, String updatedAt}), ({String id, JsonMap data, String createdAt, String updatedAt})) comparator(List<SortKey> sort) {
  final keys = [...sort, if (!sort.any((k) => k.field == r'$id')) const SortKey(r'$id')];
  Object? val(({String id, JsonMap data, String createdAt, String updatedAt}) d, String f) =>
      f == r'$id' ? d.id : f == r'$createdAt' ? d.createdAt : f == r'$updatedAt' ? d.updatedAt : getPath(d.data, f);
  return (a, b) {
    for (final k in keys) {
      final c = compareTotal(val(a, k.field), val(b, k.field));
      if (c != 0) return k.descending ? -c : c;
    }
    return 0;
  };
}

// ── update operators ──────────────────────────────────────────────────────

bool isOperatorUpdate(JsonMap body) => body.isNotEmpty && body.keys.every((k) => k.startsWith(r'$'));

void _setPath(JsonMap obj, List<String> segs, Object? v) {
  var cur = obj;
  for (final s in segs.sublist(0, segs.length - 1)) {
    final next = cur[s];
    if (next is! Map) cur[s] = <String, Object?>{};
    cur = (cur[s] as Map).cast<String, Object?>();
  }
  cur[segs.last] = v;
}

void _unsetPath(JsonMap obj, List<String> segs) {
  Object? cur = obj;
  for (final s in segs.sublist(0, segs.length - 1)) {
    if (cur is! Map) return;
    cur = cur[s];
  }
  if (cur is Map) cur.remove(segs.last);
}

Object? deepMerge(Object? base, Object? patch) {
  if (patch is! Map) return jsonClone(patch);
  final out = base is Map ? jsonClone(base).cast<String, Object?>() : <String, Object?>{};
  patch.forEach((k, v) {
    if (v == null) {
      out.remove(k);
    } else {
      out['$k'] = deepMerge(out['$k'], v);
    }
  });
  return out;
}

/// Apply an update body (operators, or a plain map = shallow `$set`). Returns
/// the new document and the top-level keys it touched; never mutates [current].
({JsonMap data, List<String> touched}) applyUpdate(JsonMap current, JsonMap body, [DateTime? now]) {
  final out = jsonClone(current).cast<String, Object?>();
  final touched = <String>{};
  final spec = isOperatorUpdate(body) ? body : {r'$set': body};
  final ts = (now ?? DateTime.now()).toUtc().toIso8601String();
  for (final e in spec.entries) {
    final op = e.key;
    final arg = e.value;
    if (op == r'$unset' || op == r'$serverTime') {
      final fields = arg is List ? arg.cast<String>() : (arg as Map).keys.cast<String>();
      for (final f in fields) {
        final segs = f.split('.');
        touched.add(segs.first);
        op == r'$unset' ? _unsetPath(out, segs) : _setPath(out, segs, ts);
      }
      continue;
    }
    (arg as Map).forEach((field, v) {
      final f = field as String;
      final segs = f.split('.');
      touched.add(segs.first);
      final cur = getPath(out, f);
      switch (op) {
        case r'$set':
          _setPath(out, segs, jsonClone(v));
        case r'$merge':
          _setPath(out, segs, deepMerge(cur, v));
        case r'$inc':
          _setPath(out, segs, (cur is num ? cur : 0) + (v as num));
        case r'$mul':
          _setPath(out, segs, (cur is num ? cur : 0) * (v as num));
        case r'$min':
        case r'$max':
          final c = compareBracketed(v, cur);
          if (cur == null || (c != null && (op == r'$min' ? c < 0 : c > 0))) _setPath(out, segs, v);
        case r'$push':
        case r'$addToSet':
          final list = cur is List ? [...cur] : <Object?>[];
          final each = v is Map && v[r'$each'] is List ? v[r'$each'] as List : [v];
          for (final item in each) {
            if (op == r'$push' || !list.any((x) => deepEqual(x, item))) list.add(jsonClone(item));
          }
          final slice = v is Map && v[r'$slice'] is int ? v[r'$slice'] as int : null;
          _setPath(out, segs, slice == null ? list : slice < 0 ? list.sublist(max(0, list.length + slice)) : list.sublist(0, min(slice, list.length)));
        case r'$pull':
          final list = cur is List ? cur : const [];
          final remove = v is Map && v[r'$in'] is List ? v[r'$in'] as List : [v];
          _setPath(out, segs, list.where((x) => !remove.any((r) => deepEqual(x, r))).toList());
        case r'$pop':
          final list = cur is List ? [...cur] : <Object?>[];
          if (list.isNotEmpty) v == -1 ? list.removeAt(0) : list.removeLast();
          _setPath(out, segs, list);
        case r'$rename':
          final to = (v as String).split('.');
          touched.add(to.first);
          if (cur != null) {
            _unsetPath(out, segs);
            _setPath(out, to, cur);
          }
        default:
          throw ArgumentError("unknown update operator '$op'");
      }
    });
  }
  return (data: out, touched: touched.toList());
}

// ── hybrid logical clock ──────────────────────────────────────────────────

/// HLC strings `<13-digit ms>-<4-digit counter>-<node>` — lexicographically
/// ordered and identical in format to the server's.
class Hlc {
  Hlc(this.node) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(node)) {
      throw ArgumentError('HLC node id must be 1–32 of [A-Za-z0-9_-]');
    }
  }
  final String node;
  int _lastMs = 0;
  int _counter = 0;

  String now([int? wall]) {
    final w = wall ?? DateTime.now().millisecondsSinceEpoch;
    if (w > _lastMs) {
      _lastMs = w;
      _counter = 0;
    } else {
      _counter++;
    }
    return '${'$_lastMs'.padLeft(13, '0')}-${'${_counter % 10000}'.padLeft(4, '0')}-$node';
  }

  void observe(String remote) {
    final ms = int.tryParse(remote.substring(0, min(13, remote.length))) ?? 0;
    if (ms > _lastMs && ms < DateTime.now().millisecondsSinceEpoch + 300000) {
      _lastMs = ms;
      _counter = remote.length >= 18 ? int.tryParse(remote.substring(14, 18)) ?? 0 : 0;
    }
  }
}

/// A sortable, URL-safe 20-character id (9 chars of time + 11 random), the
/// same shape the server generates.
String newDocId() {
  const a = '0123456789abcdefghijklmnopqrstuvwxyz';
  final rnd = Random.secure();
  var n = DateTime.now().millisecondsSinceEpoch;
  final t = StringBuffer();
  final chars = <String>[];
  for (var i = 0; i < 9; i++) {
    chars.insert(0, a[n % 36]);
    n ~/= 36;
  }
  t.writeAll(chars);
  for (var i = 0; i < 11; i++) {
    t.write(a[rnd.nextInt(36)]);
  }
  return t.toString();
}
