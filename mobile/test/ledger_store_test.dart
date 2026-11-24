import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ledger_app/api/api_client.dart';
import 'package:ledger_app/ledger/ledger_store.dart';
import 'package:ledger_app/ledger/models.dart';
import 'package:ledger_app/ledger/ops.dart';

class FakeSession extends SessionStore {
  @override
  Future<String?> get accessToken async => 'token';
  @override
  Future<String?> get refreshToken async => 'refresh';
  @override
  Future<String?> get role async => 'client';
  @override
  Future<String?> get name async => 'Test';
  @override
  Future<String?> get owner async => 'a@x.com';
  @override
  Future<void> clear() async {}
}

LUser user(String name, {String? id}) => LUser(id: id ?? newUuid(), name: name, username: name.toLowerCase(), commissionPercent: 10, odd: 80);

/// Waits until the background syncs started by run()/start() are finished and the queue is empty.
Future<void> settle(LedgerStore s) async {
  for (var i = 0; i < 100; i++) {
    while (s.syncing) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (s.pending == 0) return;
    await s.sync();
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ledger_store_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  LedgerStore makeStore(http.Client client, {String owner = 'a@x.com'}) => LedgerStore(
        api: ApiClient(baseUrl: 'http://test', store: FakeSession(), httpClient: client),
        file: File('${tmp.path}/ledger.json'),
        owner: owner,
      );

  test('offline: changes are applied, saved and survive a restart', () async {
    final offline = MockClient((_) async => throw const SocketException('offline'));
    final s1 = makeStore(offline);
    await s1.start();
    await s1.run(Ops.userCreate(user('Aung')));
    await s1.sync();
    expect(s1.data.users.length, 1);
    expect(s1.pending, 1);
    expect(s1.lastError, isNotNull);
    s1.dispose();

    final s2 = makeStore(offline);
    await s2.start();
    expect(s2.data.users.single.name, 'Aung', reason: 'queued op re-applied after restart');
    expect(s2.pending, 1);
    s2.dispose();
  });

  test('a different owner never reuses the local copy', () async {
    final offline = MockClient((_) async => throw const SocketException('offline'));
    final s1 = makeStore(offline);
    await s1.start();
    await s1.run(Ops.userCreate(user('Aung')));
    s1.dispose();
    final s2 = makeStore(offline, owner: 'b@x.com');
    await s2.start();
    expect(s2.data.users, isEmpty);
    expect(s2.pending, 0);
    s2.dispose();
  });

  test('online: ops are sent once, server snapshot replaces local state, rejected ops are listed', () async {
    final sent = <Map<String, dynamic>>[];
    final serverUser = user('Server', id: newUuid());
    final client = MockClient((req) async {
      if (req.method == 'POST' && req.url.path == '/v1/client/ledger/sync') {
        final ops = ((jsonDecode(req.body) as Map)['ops'] as List).cast<Map<String, dynamic>>();
        sent.addAll(ops);
        final results = [
          for (final op in ops)
            op['type'] == 'blocked.set'
                ? {'opId': op['opId'], 'status': 'error', 'code': 'INVALID_OPERATION', 'message': 'nope'}
                : {'opId': op['opId'], 'status': 'ok'}
        ];
        return http.Response(jsonEncode({'results': results}), 200);
      }
      if (req.url.path == '/v1/client/ledger/snapshot') {
        return http.Response(jsonEncode({'serverTime': 'now', 'users': [serverUser.toJson()], 'entries': [], 'blockedNumbers': [], 'drawResults': [], 'coverVouchers': [], 'finalizedRecords': []}), 200);
      }
      return http.Response('{}', 404);
    });
    final s = makeStore(client);
    await s.start();
    await s.run(Ops.userCreate(user('Local')));
    await s.run(Ops.blockedSet(['13']));
    await settle(s);
    expect(s.pending, 0);
    expect(s.data.users.single.name, 'Server');
    expect(s.failed.single.what, 'blocked.set');
    expect(sent.map((o) => o['type']), containsAll(['user.create', 'blocked.set']));
    final before = sent.length;
    await s.sync();
    expect(sent.length, before, reason: 'nothing is re-sent once acknowledged');
    s.dispose();
  });

  test('rules refuse bad operations without queueing them', () async {
    final s = makeStore(MockClient((_) async => throw const SocketException('offline')));
    await s.start();
    final u = user('Aung');
    await s.run(Ops.userCreate(u));
    await expectLater(s.run(Ops.userCreate(user('Aung'))), throwsA(isA<LedgerRule>()));
    await s.run(Ops.blockedSet(['13']));
    final e = LEntry(id: newUuid(), userId: u.id, code: 'V1', mode: 'manual', date: today(), createdAt: '', lines: const [Line('13', 100)]);
    await expectLater(s.run(Ops.entryCreate(e)), throwsA(isA<LedgerRule>()));
    expect(s.pending, 2);
    s.dispose();
  });

  test('offline plan check: ended plan, too long offline and clock moved back block changes', () async {
    final s = makeStore(MockClient((_) async => throw const SocketException('offline')));
    await s.start();
    await s.run(Ops.userCreate(user('Aung')));

    s.accessUntil = DateTime.now().subtract(const Duration(minutes: 1));
    expect(s.lockReason(), 'PLAN_EXPIRED');
    await expectLater(s.run(Ops.userCreate(user('B'))), throwsA(isA<LedgerRule>().having((e) => e.code, 'code', 'PLAN_EXPIRED')));

    s.accessUntil = DateTime.now().add(const Duration(days: 30));
    s.lastServerContact = DateTime.now().subtract(const Duration(days: 8));
    expect(s.lockReason(), 'OFFLINE_TOO_LONG');

    s.lastServerContact = DateTime.now();
    s.lastSeen = DateTime.now().add(const Duration(days: 3)); // as if the clock was set back 3 days
    expect(s.lockReason(), 'CLOCK_CHANGED');

    s.lastSeen = DateTime.now();
    expect(s.lockReason(), isNull);
    await s.run(Ops.userCreate(user('C')));
    expect(s.data.users.length, 2);
    s.dispose();
  });
}
