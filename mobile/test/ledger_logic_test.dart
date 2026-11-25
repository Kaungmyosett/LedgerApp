// Checks lib/ledger/logic.dart and the local reducer against values produced by the real ledger_v31.html
// (see backend/test/make-fixtures.ts). Run: flutter test
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_app/ledger/draw_period.dart';
import 'package:ledger_app/ledger/history_allocations.dart';
import 'package:ledger_app/ledger/logic.dart';
import 'package:ledger_app/ledger/models.dart';
import 'package:ledger_app/ledger/ops.dart';

List<Line> lines(Object? v) => (v as List).map((x) => Line.fromJson(x as Map<String, dynamic>)).toList();
void sameLines(List<Line> got, List<Line> want, String ctx) {
  expect(got.length, want.length, reason: ctx);
  for (var i = 0; i < got.length; i++) {
    expect(got[i].num, want[i].num, reason: '$ctx [$i]');
    expect(got[i].amount, want[i].amount, reason: '$ctx [$i]');
  }
}

void main() {
  final fx = jsonDecode(File('test/fixtures/ledger_golden.json').readAsStringSync()) as Map<String, dynamic>;

  test('draw periods match date and switch at 13:00', () {
    final morning = DateTime(2026, 11, 25, 12, 59);
    final evening = DateTime(2026, 11, 25, 13);
    final data = LedgerData(drawResults: const [
      LDraw(date: '2026-11-24', session: 'evening', number: '09'),
      LDraw(date: '2026-11-25', session: 'morning', number: '25'),
    ], entries: [
      LEntry(id: 'entry', userId: 'a', code: '', mode: 'manual',
          date: '2026-11-25', createdAt: morning.toUtc().toIso8601String(),
          lines: const [Line('00', 1000)]),
    ]);
    expect(nextDrawPeriod(morning), evening);
    expect(data.drawFor(drawPeriodAt(morning))?.number, '25');
    expect(data.entriesFor(drawPeriodAt(morning)), hasLength(1));
    expect(data.drawFor(drawPeriodAt(evening)), isNull);
    expect(data.entriesFor(drawPeriodAt(evening)), isEmpty);
    expect(data.drawFor(drawPeriodAt(DateTime(2026, 11, 26, 12))), isNull);
  });

  test('history splits allocations per number and preserves the last cent', () {
    final entries = [
      for (final user in ['b', 'a', 'c'])
        LEntry(id: user, userId: user, code: '', mode: 'manual', date: '2026-11-25',
            createdAt: '', lines: [const Line('00', 1), if (user == 'a') const Line('01', 4)]),
    ];
    const covers = [
      LCover(id: 'cover', code: '', seq: 1, requestedAmount: 1, coverListTotal: 3,
          date: '2026-11-25', createdAt: '', allocations: [Line('00', 1)],
          remainingLines: [Line('01', 3)]),
    ];
    final shares = historyAllocations(entries, covers);
    expect(shares['a'], (eaten: 0.34, covered: 3.0));
    expect(shares['b'], (eaten: 0.33, covered: 0.0));
    expect(shares['c'], (eaten: 0.33, covered: 0.0));
  });

  test('a double (00, 11, …) is never charged twice', () {
    Map<String, double> amt(String raw) => {for (final l in parseFormat(raw).result) l.num: l.amount};
    expect(amt('00/11 R1000'), {'00': 1000.0, '11': 1000.0});
    expect(amt('00/11-R1000'), amt('00/11-1000'));
    expect(amt('12/00 R1000'), {'12': 1000.0, '21': 1000.0, '00': 1000.0});
    final pp = amt('1PP 1000');
    expect(pp.length, 19);
    expect(pp['11'], 1000.0);
    expect(amt('0PP 500')['00'], 500.0);
    expect(amt('11-1000\n11-1000'), {'11': 2000.0});
  });

  test('format parser matches the HTML', () {
    final cases = fx['parse'] as List;
    expect(cases, isNotEmpty);
    for (final c in cases) {
      final r = parseFormat(c['input'] as String);
      sameLines(r.result, lines(c['result']), 'parse "${c['input']}"');
      expect(r.errors, (c['errors'] as List).cast<String>(), reason: 'errors for "${c['input']}"');
    }
  });

  test('blocked-number parser matches the HTML', () {
    for (final c in fx['blocked'] as List) {
      expect(parseBlockedNumbers(c['input'] as String), (c['result'] as List).cast<String>(), reason: '"${c['input']}"');
    }
  });

  test('balances, cover vouchers (v0.6.1 rule), numbers summary and finalize', () {
    final scenarios = fx['scenarios'] as List;
    for (var si = 0; si < scenarios.length; si++) {
      final s = scenarios[si] as Map<String, dynamic>;
      final users = (s['users'] as List).map((x) => LUser.fromJson(x as Map<String, dynamic>)).toList();
      final entries = (s['entries'] as List)
          .map((x) => LEntry(id: x['id'], userId: x['userId'], code: '', mode: 'manual', date: x['date'], createdAt: '', lines: lines(x['lines'])))
          .toList();
      final draws = (s['draws'] as List).map((x) => LDraw(date: x['date'], session: x['session'], number: x['number'])).toList();
      final ctx = 'scenario $si';

      // HTML check (no cover vouchers): gross per number.
      final noCover = numberBalances(entries, const []);
      (s['balancesNoCover'] as Map<String, dynamic>).forEach((n, v) {
        expect(noCover[n]!.gross, (v['gross'] as num).toDouble(), reason: '$ctx html gross $n');
        expect(noCover[n]!.remaining, (v['remaining'] as num).toDouble(), reason: '$ctx html remaining $n');
      });

      // Replay cover operations (owner's v0.6.1 rule; expected values from logic.ts).
      final covers = <LCover>[];
      var seq = 0;
      for (final op in s['coverOps'] as List) {
        final kind = op['kind'];
        if (kind == 'delete') {
          covers.removeAt(op['index'] as int);
          continue;
        }
        final ents = entries.take(op['entryCount'] as int).toList();
        final req = (op['requested'] as num).toDouble();
        if (covers.isNotEmpty) expect(lockedEat(covers), req, reason: '$ctx locked eat');
        final r = makeCoverVoucher(buildCoverPlan(numberBalances(ents, covers), req));
        if (kind == 'refused') {
          expect(r, isNull, reason: '$ctx cover should be refused');
          continue;
        }
        expect(r, isNotNull, reason: '$ctx cover should be created');
        sameLines(r!.allocations, lines(op['allocations']), '$ctx cover eat');
        sameLines(r.remainingLines, lines(op['remainingLines']), '$ctx cover list');
        expect(r.remainingTotal, (op['remainingTotal'] as num).toDouble(), reason: ctx);
        covers.add(LCover(id: 'c${++seq}', code: '', seq: seq, requestedAmount: req, coverListTotal: r.remainingTotal, date: '', createdAt: '', allocations: r.allocations, remainingLines: r.remainingLines));
      }

      final bal = numberBalances(entries, covers);
      (s['balances'] as Map<String, dynamic>).forEach((n, v) {
        expect(bal[n]!.gross, (v['gross'] as num).toDouble(), reason: '$ctx gross $n');
        expect(bal[n]!.covered, (v['covered'] as num).toDouble(), reason: '$ctx covered $n');
        expect(bal[n]!.cover, (v['cover'] as num).toDouble(), reason: '$ctx cover $n');
        expect(bal[n]!.remaining, (v['remaining'] as num).toDouble(), reason: '$ctx remaining $n');
      });

      final sum = numbersSummary(users, entries, covers, draws);
      final want = s['summary'] as Map<String, dynamic>;
      expect(sum.activeCount, want['activeCount'], reason: ctx);
      expect(sum.winning, want['winning'], reason: ctx);
      for (final e in {
        'totalGross': sum.totalGross, 'totalEaten': sum.totalEaten, 'totalCover': sum.totalCover, 'winGross': sum.winGross,
        'avgOdd': sum.avgOdd, 'avgWinnerCommission': sum.avgWinnerCommission, 'yourEaten': sum.yourEaten, 'otherDealerCover': sum.otherDealerCover,
      }.entries) {
        expect(e.value, closeTo((want[e.key] as num).toDouble(), 1e-9), reason: '$ctx ${e.key}');
      }

      // Finalize through the reducer (same path the phone uses) and compare the history rows.
      final fin = s['finalize'];
      if (fin != null) {
        final data = LedgerData(users: users, entries: entries, drawResults: draws);
        final recs = fin['records'] as List;
        if (recs.isEmpty) {
          // Nobody had a stake on that date: finalize is refused and nothing changes.
          expect(() => applyOpLocally(data, Ops.finalize(fin['date'], fin['session'], const {})), throwsA(isA<LedgerRule>()), reason: ctx);
          continue;
        }
        applyOpLocally(data, Ops.finalize(fin['date'], fin['session'], const {}));
        expect(data.finalizedRecords.length, recs.length, reason: ctx);
        for (var i = 0; i < recs.length; i++) {
          final g = data.finalizedRecords[i], w = recs[i] as Map<String, dynamic>;
          expect(g.userId, w['userId'], reason: ctx);
          expect(g.number, fin['number'], reason: ctx);
          for (final e in {'total': g.total, 'winAmount': g.winAmount, 'odd': g.odd, 'payout': g.payout, 'commission': g.commission, 'payment': g.payment, 'net': g.net}.entries) {
            // The HTML keeps full precision; the server (and phone) store money rounded to 2 decimals on purpose.
            final expected = e.key == 'odd' ? (w[e.key] as num).toDouble() : round2((w[e.key] as num).toDouble());
            expect(e.value, closeTo(expected, 1e-9), reason: '$ctx rec $i ${e.key}');
          }
        }
        final settled = recs.map((r) => r['userId']).toSet();
        for (final u in data.users) {
          final before = users.firstWhere((x) => x.id == u.id).payment;
          expect(u.payment, settled.contains(u.id) ? isNull : before, reason: '$ctx payment of ${u.id}');
        }
        for (final g in data.finalizedRecords) {
          expect(g.total, isNot(0), reason: '$ctx zero-stake user must not get a history row');
        }
        expect(data.entries.where((e) => e.date == fin['date']), isEmpty);
      }
    }
  });

  test("owner's cover example: eat 1,000 fixed, second voucher lists only changes", () {
    LEntry e(String id, List<Line> l) => LEntry(id: id, userId: 'u', code: '', mode: 'manual', date: '2026-11-20', createdAt: '', lines: l);
    final data = LedgerData(users: [const LUser(id: 'u', name: 'U', username: 'U', commissionPercent: 0, odd: 80)], entries: [e('e1', const [Line('05', 5000)])]);
    applyOpLocally(data, Ops.coverCreate('c1', 'C1', 1000, '2026-11-20'));
    data.entries.add(e('e2', const [Line('05', 2000), Line('12', 3000)]));
    expect(() => applyOpLocally(data, Ops.coverCreate('c2', 'C2', 2000, '2026-11-20')), throwsA(isA<LedgerRule>()));
    applyOpLocally(data, Ops.coverCreate('c3', 'C3', 1000, '2026-11-20'));
    final v = data.coverVouchers.last;
    expect(v.allocations.map((x) => '${x.num}=${x.amount}'), ['12=1000.0']);
    expect(v.remainingLines.map((x) => '${x.num}=${x.amount}'), ['05=2000.0', '12=2000.0']);
  });

  test('Format: "Apu-1000" and Myanmar words (same cases as the server test)', () {
    String key(ParseResult r) => '${r.result.map((x) => '${x.num}=${x.amount}').join(',')}|${r.errors.join(',')}';
    void same(String a, String b) => expect(key(parseFormat(a)), key(parseFormat(b)), reason: '$a vs $b');
    for (final sep in ['-', '=', '', ' - ']) {
      same('Apu${sep}1000', 'Apu 1000');
    }
    same('power-500', 'Power 500');
    same('အပူး 1000', 'Apu 1000');
    same('အပူး-1000', 'Apu 1000');
    same('3ပါတ်200', '3PP200');
    same('3 ပါတ် 200', '3PP200');
    same('5ထိပ်100', '5TO100');
    same('5ပိတ်100', '5BO100');
    same('ပါဝါ 300', 'Power 300');
    same('နက္ခတ်-300', 'Natkat 300');
    same('3\u1015\u102b\u1010\u103a200', '3PP200'); // ပါတ် typed with the tall aa
    expect(parseFormat('ပါတ် 200').errors, ['Format မမှန်ပါ: ပါတ် 200']);
    same('1ပါတ်=100', '1PP100');
    same('1ထိပ်=100', '1TO100');
    same('1ပိတ်=100', '1BO100');
    same('8Bk=500', '8BK500');
    same('17=R2500', '17R2500');
    same('25/70/50/73=R15000', '25/70/50/73R15000');
    same('17R=2500', '17R2500');
    same('apu=500', 'Apu 500');
    expect(parseFormat('17=R2500\n8Bk=500\n1ပါတ်=100').errors, isEmpty);
    same('ညီကို 1000', 'Nyiko 1000');
    same('ညီကို=1000', 'Nyiko 1000');
    for (final sep in ['', '-', '=', ' - ']) {
      same('012ခွေ${sep}1000', '01/02/10/12/20/21=1000');
      same('012ခွေပူး${sep}1000', '01/02/10/12/20/21/00/11/22=1000');
    }
    same('0112ခွေ500', '01/02/10/12/20/21=500');
    expect(parseFormat('0123456789ခွေ100').result.length, 90);
    expect(parseFormat('0123456789ခွေပူး=100').result.length, 100);
    expect(parseFormat('01234567890123ခွေ100').result.length, 90);
    expect(parseFormat('1ခွေ1000').errors.length, 1);
    expect(parseFormat('13579ခွေ-100').result.length, 20);
    expect(parseFormat('11ခွေ1000').errors.length, 1);
  });

  test('latest draw: newest date, evening before morning', () {
    final d = sortDraws([
      const LDraw(date: '2026-11-18', session: 'evening', number: '11'),
      const LDraw(date: '2026-11-19', session: 'morning', number: '22'),
      const LDraw(date: '2026-11-19', session: 'evening', number: '33'),
    ]);
    expect(d.map((x) => x.number).toList(), ['33', '22', '11']);
  });

  test('round2 rounds half away from zero', () {
    expect(round2(2.5), 2.5);
    expect(round2(0.125), 0.13);
    expect(round2(-0.125), -0.13);
    expect(round2(1499.999), 1500);
    expect(round2(1277.7), 1277.7);
  });
}
