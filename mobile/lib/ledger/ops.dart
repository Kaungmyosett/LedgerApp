// Offline operations. Each one is a small "intent" with a client-generated opId and entity ids.
// The server applies them idempotently (same opId twice = applied once), so retrying is always safe.
import 'dart:math';

import 'draw_period.dart';
import 'history_allocations.dart';
import 'logic.dart';
import 'models.dart';

final _rng = Random.secure();

String newUuid() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}

/// Voucher code shown on the phone: V######## (bets) or C######## (cover). The server keeps it unless already used.
String newVoucherCode(String prefix) => prefix + (10000000 + _rng.nextInt(90000000)).toString();

String today() => ledgerDate(DateTime.now());

/// A queued operation is just JSON, so it survives app restarts exactly as sent.
typedef Op = Map<String, dynamic>;

Op _op(String type, Map<String, dynamic> rest) => {'opId': newUuid(), 'type': type, ...rest};
List<Map<String, dynamic>> _ls(List<Line> l) => l.map((x) => x.toJson()).toList();

abstract class Ops {
  static Op userCreate(LUser u) => _op('user.create', {'id': u.id, 'name': u.name, 'username': u.username, 'commissionPercent': u.commissionPercent, 'odd': u.odd, 'payment': u.payment, 'settlementSchedule': u.settlementSchedule.name});
  static Op userUpdate(LUser u) => _op('user.update', {'id': u.id, 'name': u.name, 'username': u.username, 'commissionPercent': u.commissionPercent, 'odd': u.odd, 'payment': u.payment, 'settlementSchedule': u.settlementSchedule.name});
  static Op userDelete(String id) => _op('user.delete', {'id': id});
  static Op entryCreate(LEntry e) => _op('entry.create', {'id': e.id, 'userId': e.userId, 'code': e.code, 'mode': e.mode, 'date': e.date, if (e.session != null) 'session': e.session, 'createdAt': e.createdAt, 'lines': _ls(e.lines)});
  static Op entryUpdate(String id, List<Line> lines) => _op('entry.update', {
    'id': id, 'lines': _ls(lines), 'createdAt': DateTime.now().toUtc().toIso8601String(),
  });
  static Op entryDelete(String id) => _op('entry.delete', {'id': id});
  static Op blockedLogDelete(String blockedOpId, String number) =>
      _op('blocked.log.delete', {'blockedOpId': blockedOpId, 'num': number});
  static Op blockedSet(List<String> numbers) => _op('blocked.set', {'numbers': numbers});
  static Op drawSave(String date, String session, String number) => _op('draw.save', {'date': date, 'session': session, 'number': number});
  static Op drawDelete(String date, String session) => _op('draw.delete', {'date': date, 'session': session});
  static Op coverCreate(String id, String code, double requested, String date, {String? session}) =>
      _op('cover.create', {'id': id, 'code': code, 'requestedAmount': requested, 'date': date, if (session != null) 'session': session,
        'createdAt': DateTime.now().toUtc().toIso8601String()});
  static Op coverDelete(String id) => _op('cover.delete', {'id': id});
  static Op finalize(String date, String session, Map<String, String> recordIds) => _op('finalize', {'date': date, 'session': session, 'recordIds': recordIds});
  static Op debtRecord(String userId, String date, String kind, double amount) =>
      _op('debt.record', {'id': newUuid(), 'userId': userId, 'date': date, 'kind': kind, 'amount': amount});
  static Op finalizedDelete(String id) => _op('finalized.delete', {'id': id});
}

/// Why an operation can't be applied. Used both locally (before queueing) and for server answers.
class LedgerRule implements Exception {
  LedgerRule(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// Applies [op] to [d] in place, the same way the server will. The server stays authoritative:
/// after each sync the phone replaces its copy with the server snapshot and re-applies still-queued ops.
/// Throws [LedgerRule] when the operation can't apply (e.g. unknown user, blocked number).
void applyOpLocally(LedgerData d, Op op) {
  final type = op['type'] as String;
  switch (type) {
    case 'user.create':
      if (d.users.any((u) => u.id == op['id'])) return;
      if (d.users.any((u) => u.username == op['username'])) throw LedgerRule('USERNAME_TAKEN', 'ဤအမည် "${op['name']}" ရှိပြီးသားဖြစ်သည်။');
      d.users.add(_userFrom(op));
    case 'user.update':
      final i = d.users.indexWhere((u) => u.id == op['id']);
      if (i < 0) throw LedgerRule('USER_NOT_FOUND', 'User not found.');
      if (d.users.any((u) => u.id != op['id'] && u.username == op['username'])) throw LedgerRule('USERNAME_TAKEN', 'ဤအမည် "${op['name']}" ရှိပြီးသားဖြစ်သည်။');
      final existing = d.users[i];
      d.users[i] = _userFrom(op, fallbackSchedule: existing.settlementSchedule)
          .copyWith(hasFinalizedVouchers: existing.hasFinalizedVouchers);
    case 'user.delete':
      final id = op['id'];
      if (d.users.any((u) => u.id == id && u.hasFinalizedVouchers) ||
          d.entries.any((e) => e.userId == id) ||
          d.finalizedRecords.any((r) => r.userId == id) ||
          d.debtEntries.any((r) => r.userId == id)) {
        throw LedgerRule('USER_IN_USE', 'This commission user has vouchers, history or debt entries.');
      }
      d.users.removeWhere((u) => u.id == id);
    case 'entry.create':
      if (d.entries.any((e) => e.id == op['id'])) return;
      final user = d.users.where((u) => u.id == op['userId']).firstOrNull;
      if (user == null) throw LedgerRule('USER_NOT_FOUND', 'User not found.');
      final created = DateTime.tryParse(op['createdAt'] as String? ?? '') ?? DateTime.now();
      final period = (date: op['date'] as String, session: op['session'] as String? ?? legacyDrawSession(created));
      final lines = _excludeBlocked(d, op, user.id, user.name);
      if (lines.isEmpty) return;
      _requireOpenDraw(d, period);
      d.entries.add(LEntry(
        id: op['id'] as String, userId: user.id, code: (op['code'] ?? '') as String, mode: op['mode'] as String,
        date: period.date, createdAt: created.toUtc().toIso8601String(),
        session: period.session, lines: lines));
    case 'entry.update':
      final i = d.entries.indexWhere((e) => e.id == op['id']);
      if (i < 0) throw LedgerRule('ENTRY_NOT_FOUND', 'Voucher not found.');
      final entry = d.entries[i];
      final userName = d.users.where((u) => u.id == entry.userId).firstOrNull?.name ?? '';
      final lines = _excludeBlocked(d, op, entry.userId, userName);
      if (lines.isNotEmpty) d.entries[i] = entry.withLines(lines);
    case 'entry.delete':
      d.entries.removeWhere((e) => e.id == op['id']);
    case 'blocked.log.delete':
      d.blockedLog.removeWhere((row) => row.opId == op['blockedOpId'] && row.num == op['num']);
    case 'blocked.set':
      final l = (op['numbers'] as List).map((x) => x as String).toSet().toList()..sort();
      d.blockedNumbers = l;
    case 'draw.save':
      d.drawResults.removeWhere((x) => x.date == op['date'] && x.session == op['session']);
      d.drawResults.add(LDraw(date: op['date'] as String, session: op['session'] as String, number: op['number'] as String));
    case 'draw.delete':
      d.drawResults.removeWhere((x) => x.date == op['date'] && x.session == op['session']);
    case 'cover.create':
      if (d.coverVouchers.any((v) => v.id == op['id'])) return;
      final eat = (op['requestedAmount'] as num).toDouble();
      final created = DateTime.tryParse(op['createdAt'] as String? ?? '') ?? DateTime.now();
      final period = (date: op['date'] as String, session: op['session'] as String? ?? legacyDrawSession(created));
      _requireOpenDraw(d, period);
      final covers = d.coversFor(period);
      final locked = lockedEat(covers);
      if (locked != null && locked != eat) throw LedgerRule('EAT_LOCKED', 'စားငွေကို ပထမကာဘောင်ချာအတိုင်း ${locked.toStringAsFixed(0)} သာ သုံးနိုင်သည်။');
      final plan = buildCoverPlan(numberBalances(d.entriesFor(period), covers), eat);
      final r = makeCoverVoucher(plan);
      if (r == null) throw LedgerRule('NO_COVER', 'ကာငွေမရှိပါ — သိမ်းရန် ကာမည့်ငွေ မရှိပါ။');
      final seq = d.coverVouchers.fold<int>(0, (m, v) => v.seq > m ? v.seq : m) + 1;
      d.coverVouchers.add(LCover(
        id: op['id'] as String, code: (op['code'] ?? '') as String, seq: seq, requestedAmount: (op['requestedAmount'] as num).toDouble(),
        coverListTotal: r.remainingTotal, date: period.date, session: period.session,
        createdAt: created.toUtc().toIso8601String(),
        allocations: r.allocations, remainingLines: r.remainingLines));
    case 'cover.delete':
      d.coverVouchers.removeWhere((v) => v.id == op['id']);
    case 'finalize':
      final date = op['date'] as String, session = op['session'] as String;
      final draw = d.drawResults.where((x) => x.date == date && x.session == session).firstOrNull;
      if (draw == null) throw LedgerRule('DRAW_NOT_FOUND', 'No draw result for this date and session.');
      final period = (date: date, session: session);
      _requireOpenDraw(d, period);
      final ids = Map<String, dynamic>.from((op['recordIds'] ?? const {}) as Map);
      final dayEntries = d.entriesFor(period);
      final userIds = d.users.map((user) => user.id).toSet();
      final shares = historyAllocations(
        dayEntries.where((entry) => userIds.contains(entry.userId)),
        d.coversFor(period),
      );
      final settled = <String>{};
      final records = <LFinal>[];
      final debtPostings = <LDebtEntry>[];
      final createdAt = DateTime.now().toUtc().toIso8601String();
      for (final u in d.users) {
        final lines = dayEntries.where((e) => e.userId == u.id).expand((e) => e.lines).toList();
        final s = settleUser(u, lines, draw.number);
        if (s.total == 0) continue; // no stake on this date -> no history row, payment kept
        settled.add(u.id);
        final recordId = (ids[u.id] as String?) ?? newUuid();
        final net = round2(s.net);
        records.add(LFinal(
          id: recordId, userId: u.id, userName: u.name, date: date, session: session, number: draw.number,
          total: round2(s.total), winAmount: round2(s.winAmount), odd: s.odd, payout: round2(s.payout), commission: round2(s.commission),
          payment: round2(s.payment), net: net, eaten: shares[u.id]?.eaten ?? 0,
          covered: shares[u.id]?.covered ?? 0, createdAt: createdAt));
        if (u.settlementSchedule == SettlementSchedule.weekly) {
          debtPostings.add(LDebtEntry(
            id: recordId, userId: u.id, userName: u.name, date: date, session: session,
            kind: 'settlement', amount: net, createdAt: createdAt,
          ));
        }
      }
      if (records.isEmpty) throw LedgerRule('NOTHING_TO_FINALIZE', 'No commission user has a stake on this date.');
      d.finalizedRecords.addAll(records);
      d.debtEntries.addAll(debtPostings);
      d.users = d.users.map((u) => settled.contains(u.id) ? u.copyWith(clearPayment: true, hasFinalizedVouchers: true) : u).toList();
      final entryIds = dayEntries.map((entry) => entry.id).toSet();
      final coverIds = d.coversFor(period).map((cover) => cover.id).toSet();
      d.entries.removeWhere((e) => entryIds.contains(e.id));
      d.coverVouchers.removeWhere((cover) => coverIds.contains(cover.id));
    case 'debt.record':
      final id = op['id'] as String;
      if (d.debtEntries.any((entry) => entry.id == id && entry.kind != 'settlement')) return;
      final userId = op['userId'] as String;
      final date = op['date'] as String;
      final kind = op['kind'] as String;
      final amount = (op['amount'] as num).toDouble();
      final user = d.users.where((user) => user.id == userId).firstOrNull;
      final entries = d.debtEntries.where((entry) => entry.userId == userId);
      final name = user?.name ?? (kind == 'repayment' ? entries.lastOrNull?.userName : null);
      if (name == null) throw LedgerRule('USER_NOT_FOUND', 'Commission user not found.');
      if (!amount.isFinite || amount <= 0 || amount > 1e12) {
        throw LedgerRule('INVALID_OPERATION', 'Invalid debt amount.');
      }
      if (kind == 'repayment') {
        final days = <String, int>{date: -(amount * 100).round()};
        for (final entry in entries) {
          days.update(entry.date, (change) => change + entry.changeCents,
              ifAbsent: () => entry.changeCents);
        }
        var balance = 0;
        for (final day in days.keys.toList()..sort()) {
          balance += days[day]!;
          if (day.compareTo(date) >= 0 && balance < 0) {
            throw LedgerRule('REPAYMENT_EXCEEDS_DEBT', 'Repayment exceeds the outstanding debt.');
          }
        }
      }
      d.debtEntries.add(LDebtEntry(
        id: id, userId: userId, userName: name, date: date, kind: kind,
        amount: amount, createdAt: DateTime.now().toUtc().toIso8601String(),
      ));
    case 'finalized.delete':
      d.finalizedRecords.removeWhere((r) => r.id == op['id']);
      d.debtEntries.removeWhere((entry) => entry.id == op['id'] && entry.kind == 'settlement');
    default:
      throw LedgerRule('INVALID_OPERATION', 'Unknown operation $type.');
  }
}

void _requireOpenDraw(LedgerData data, DrawPeriod period) {
  if (data.finalizedRecords.any((r) => r.date == period.date && r.session == period.session)) {
    throw LedgerRule('ALREADY_FINALIZED', 'This draw is already finalized.');
  }
}

List<Line> _excludeBlocked(LedgerData data, Op op, String userId, String userName) {
  final blocked = data.blockedNumbers.toSet();
  final lines = _linesOf(op['lines']);
  final rejected = <String, double>{};
  for (final line in lines) {
    if (blocked.contains(line.num)) {
      rejected.update(line.num, (amount) => amount + line.amount, ifAbsent: () => line.amount);
    }
  }
  final opId = op['opId'] as String;
  final logged = data.blockedLog.where((row) => row.opId == opId).map((row) => row.num).toSet();
  final at = (DateTime.tryParse(op['createdAt'] as String? ?? '') ?? DateTime.now()).toUtc().toIso8601String();
  for (final item in rejected.entries) {
    if (!logged.contains(item.key)) {
      data.blockedLog.add(LBlockedLine(opId: opId, userId: userId, userName: userName,
          num: item.key, amount: round2(item.value), createdAt: at));
    }
  }
  return lines.where((line) => !blocked.contains(line.num)).toList();
}

LUser _userFrom(Op op, {SettlementSchedule fallbackSchedule = SettlementSchedule.daily}) => LUser(
      id: op['id'] as String, name: op['name'] as String, username: op['username'] as String,
      commissionPercent: (op['commissionPercent'] as num).toDouble(), odd: (op['odd'] as num).toDouble(),
      payment: op['payment'] == null ? null : (op['payment'] as num).toDouble(),
      settlementSchedule: switch (op['settlementSchedule']) {
        'weekly' => SettlementSchedule.weekly,
        'daily' => SettlementSchedule.daily,
        _ => fallbackSchedule,
      });

List<Line> _linesOf(Object? v) => (v as List).map((x) => Line((x as Map)['num'] as String, (x['amount'] as num).toDouble())).toList();
