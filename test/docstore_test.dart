import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_flutter/src/docstore/api.dart';
import 'package:nexus_flutter/src/docstore/client.dart';
import 'package:nexus_flutter/src/docstore/core.dart';
import 'package:nexus_flutter/src/docstore/live.dart';
import 'package:nexus_flutter/src/docstore/offline.dart';

const _opts = DocStoreOptions(apiKey: 'nxs_k', baseUrl: 'https://api.test');

DocStore _store(MockClient client, {DocStoreOptions opts = _opts}) => DocStore(DocStoreHttp(opts, client: client), () => DocStoreLive(opts));

Map<String, Object?> _doc(String id, Map<String, Object?> data, [int version = 1]) =>
    {'id': id, 'data': data, 'version': version, 'createdAt': '2026-10-28T00:00:00.000Z', 'updatedAt': '2026-10-28T00:00:00.000Z'};

http.Response _json(int status, Object? body) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  group('core semantics (mirror the server)', () {
    test('type-bracketed comparisons and operators', () {
      final d = {'age': 30, 'tags': ['a', 'b'], 'name': 'Ana', 'n': '30'};
      expect(matchesFilter({'age': {r'$gte': 18, r'$lt': 65}}, 'x', d), isTrue);
      expect(matchesFilter({'n': {r'$gt': 18}}, 'x', d), isFalse, reason: 'a string never orders against a number');
      expect(matchesFilter({'tags': {r'$containsAll': ['a', 'b']}}, 'x', d), isTrue);
      expect(matchesFilter({r'$or': [{'name': 'Bo'}, {'age': 30}]}, 'x', d), isTrue);
      expect(matchesFilter({'missing': {r'$exists': false}, r'$id': 'x'}, 'x', d), isTrue);
      expect(() => matchesFilter({r'$search': 'x'}, 'x', d), throwsA(isA<LocalQueryException>()));
    });

    test('update operators', () {
      final r = applyUpdate({'n': 1, 'tags': ['a'], 'old': 1}, {
        r'$inc': {'n': 2},
        r'$addToSet': {'tags': {r'$each': ['a', 'b']}},
        r'$push': {'log': {r'$each': [1, 2, 3], r'$slice': -2}},
        r'$rename': {'old': 'renamed'},
      });
      expect(r.data, {'n': 3, 'tags': ['a', 'b'], 'log': [2, 3], 'renamed': 1});
    });

    test('field values compile to operators', () {
      expect(
        toUpdateSpec({'views': FieldValue.increment(1), 'tags': FieldValue.arrayUnion(['x']), 'at': FieldValue.serverTimestamp(), 'draft': FieldValue.delete(), 'a.b': 2}),
        {
          r'$inc': {'views': 1},
          r'$addToSet': {'tags': {r'$each': ['x']}},
          r'$serverTime': ['at'],
          r'$unset': ['draft'],
          r'$set': {'a.b': 2},
        },
      );
    });

    test('HLC orders and observes', () {
      final h = Hlc('devA');
      final a = h.now(1000);
      final b = h.now(1000);
      expect(a.compareTo(b) < 0, isTrue);
      h.observe('${'${DateTime.now().millisecondsSinceEpoch + 1000}'.padLeft(13, '0')}-0005-devB');
      expect(h.now().compareTo(b) > 0, isTrue);
    });
  });

  group('remote client', () {
    test('query builder JSON + end-user token', () async {
      late Map body;
      late http.BaseRequest seen;
      final store = _store(
        MockClient((req) async {
          seen = req;
          body = jsonDecode(req.body) as Map;
          return _json(200, {'items': [_doc('o1', {'total': 5})], 'nextCursor': 'c', 'hasMore': true});
        }),
        opts: DocStoreOptions(apiKey: 'nxs_k', baseUrl: 'https://api.test', getToken: ({required forceRefresh}) => 'jwt'),
      );
      final snap = await store
          .collection('orders')
          .where('status', whereIn: ['open', 'paid'])
          .whereFilter(Filter.or([Filter('total', isGreaterThanOrEqualTo: 100), Filter('vip', isEqualTo: true)]))
          .orderBy('total', descending: true)
          .limit(20)
          .get();
      expect(seen.headers['authorization'], 'Bearer jwt');
      expect(body, {
        'filter': {
          r'$and': [
            {'status': {r'$in': ['open', 'paid']}},
            {r'$or': [{'total': {r'$gte': 100}}, {'vip': {r'$eq': true}}]},
          ],
        },
        'sort': [{'field': 'total', 'dir': 'desc'}],
        'limit': 20,
      });
      expect(snap.docs.single.data()!['total'], 5);
      expect(snap.nextCursor, 'c');
    });

    test('typed errors; a missing doc reads as exists == false', () async {
      final store = _store(MockClient((req) async => req.url.path.endsWith('/nope')
          ? _json(404, {'error': {'code': 'not_found', 'message': 'gone'}})
          : _json(403, {'error': {'code': 'permission_denied', 'message': 'denied by rules'}})));
      expect((await store.doc('posts/nope').get()).exists, isFalse);
      expect(() => store.doc('posts/secret').get(), throwsA(isA<DocStoreException>().having((e) => e.code, 'code', 'permission_denied')));
    });

    test('runTransaction retries after a precondition race', () async {
      var balance = 100;
      var version = 3;
      var commits = 0;
      final store = _store(MockClient((req) async {
        if (req.method == 'GET') return _json(200, _doc('a', {'balance': balance}, version));
        commits++;
        if (commits == 1) {
          version++;
          return _json(409, {'error': {'code': 'conflict', 'message': 'precondition', 'details': {'reason': 'precondition_failed'}}});
        }
        final op = ((jsonDecode(req.body) as Map)['operations'] as List).first as Map;
        expect((op['precondition'] as Map)['version'], version);
        balance = ((op['data'] as Map)['balance'] as num).toInt();
        return _json(200, {'results': [{'index': 0, 'status': 'ok', 'id': 'a', 'version': ++version}]});
      }));
      final ref = store.doc('accounts/a');
      await store.runTransaction((tx) async {
        final s = await tx.get(ref);
        tx.set(ref, {'balance': (s.data()!['balance'] as num) - 30});
      });
      expect(commits, 2);
      expect(balance, 70);
    });
  });

  group('offline engine', () {
    // A tiny sync server with field-level last-writer-wins, like the real `merge` strategy.
    MockClient syncServer(Map<String, Map<String, Object?>> docs) {
      var seq = 0;
      return MockClient((req) async {
        final body = jsonDecode(req.body) as Map;
        if (req.url.path.endsWith('/sync/pull')) {
          final since = ((body['checkpoint'] as Map?)?['seq'] as num?)?.toInt() ?? 0;
          final out = docs.entries.where((e) => (e.value['seq'] as int) > since).toList()..sort((a, b) => (a.value['seq'] as int) - (b.value['seq'] as int));
          return _json(200, {
            'documents': [
              for (final e in out) {'collection': 'todos', 'id': e.key, 'version': e.value['version'], 'seq': e.value['seq'], 'deleted': false, 'data': e.value['data'], 'updatedAt': '2026-10-28T00:00:00.000Z', 'clock': e.value['clock']},
            ],
            'checkpoint': {'seq': out.isEmpty ? since : out.last.value['seq']},
            'hasMore': false,
            'resync': <String>[],
          });
        }
        final results = <Map<String, Object?>>[];
        var i = 0;
        for (final c in (body['changes'] as List).cast<Map>()) {
          final cur = docs[c['id']];
          var data = (c['data'] as Map).cast<String, Object?>();
          var clock = (c['clock'] as Map).cast<String, String>();
          if (cur != null && cur['version'] != c['baseVersion']) {
            final sd = (cur['data'] as Map).cast<String, Object?>();
            final sc = (cur['clock'] as Map).cast<String, String>();
            final md = <String, Object?>{};
            final mc = <String, String>{};
            for (final k in {...sd.keys, ...data.keys}) {
              final mine = (clock[k] ?? '').compareTo(sc[k] ?? '') > 0;
              final src = mine ? data : sd;
              if (src.containsKey(k)) md[k] = src[k];
              mc[k] = (mine ? clock[k] : sc[k]) ?? '';
            }
            data = md;
            clock = mc;
          }
          final v = ((cur?['version'] as int?) ?? 0) + 1;
          docs['${c['id']}'] = {'data': data, 'version': v, 'seq': ++seq, 'clock': {...?(cur?['clock'] as Map?)?.cast<String, String>(), ...clock}};
          results.add({'index': i++, 'status': 'ok', 'id': c['id'], 'version': v, 'doc': _doc('${c['id']}', data, v)});
        }
        return _json(200, {'results': results});
      });
    }

    test('writes are local-first, replicate, and merge with remote edits to other fields', () async {
      final server = <String, Map<String, Object?>>{};
      final off = OfflineStore(_store(syncServer(server)), collections: ['todos'], storage: MemoryDocStoreStorage(), deviceId: 'devA', live: false, pullInterval: const Duration(hours: 1));
      await off.ready;
      final todos = off.collection('todos');
      await todos.doc('t1').set({'title': 'Buy milk', 'done': false});
      expect((await todos.doc('t1').get())!.hasPendingWrites, isTrue);
      await off.sync();
      expect(off.pending, 0);
      expect((server['t1']!['data'] as Map)['title'], 'Buy milk');

      server['t1'] = {
        'data': {'title': 'Buy oat milk', 'done': false},
        'version': 2,
        'seq': 100,
        'clock': {'title': '0000000000001-0000-devB', 'done': '0000000000001-0000-devB'},
      };
      await todos.doc('t1').update({'done': true});
      await off.sync();
      expect((await todos.doc('t1').get())!.data(), {'title': 'Buy oat milk', 'done': true});
      off.stop();
    });

    test('local queries + snapshots stream', () async {
      final off = OfflineStore(_store(syncServer({})), collections: ['todos'], storage: MemoryDocStoreStorage(), live: false, pullInterval: const Duration(hours: 1));
      await off.ready;
      final todos = off.collection('todos');
      final seen = <List<String>>[];
      final sub = todos.where('done', isEqualTo: false).orderBy('rank').snapshots().listen((docs) => seen.add(docs.map((d) => d.id).toList()));
      await todos.doc('b').set({'done': false, 'rank': 2});
      await todos.doc('a').set({'done': false, 'rank': 1});
      await todos.doc('c').set({'done': true, 'rank': 0});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen.last, ['a', 'b']);
      await todos.doc('a').delete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen.last, ['b']);
      await sub.cancel();
      off.stop();
    });

    test('cache and outbox survive a restart', () async {
      final storage = MemoryDocStoreStorage();
      final failing = _store(MockClient((_) async => throw http.ClientException('offline')));
      final first = OfflineStore(failing, collections: ['todos'], storage: storage, live: false, pullInterval: const Duration(hours: 1));
      await first.ready;
      await first.collection('todos').doc('x').set({'title': 'Written offline'});
      first.stop();
      final second = OfflineStore(failing, collections: ['todos'], storage: storage, live: false, pullInterval: const Duration(hours: 1));
      await second.ready;
      expect((await second.collection('todos').doc('x').get())!.data(), {'title': 'Written offline'});
      expect(second.pending, 1);
      second.stop();
    });
  });
}
