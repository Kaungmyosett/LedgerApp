// Offline operations. Each one is a small "intent" with a client-generated opId and entity ids.
// The server applies them idempotently (same opId twice = applied once), so retrying is always safe.
import 'dart:math';

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

String today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

/// A queued operation is just JSON, so it survives app restarts exactly as sent.
typedef Op = Map<String, dynamic>;

Op _op(String type, Map<String, dynamic> rest) => {'opId': newUuid(), 'type': type, ...rest};
List<Map<String, dynamic>> _ls(List<Line> l) => l.map((x) => x.toJson()).toList();

abstract class Ops {
  static Op userCreate(LUser u) => _op('user.create', {'id': u.id, 'name': u.name, 'username': u.username, 'commissionPercent': u.commissionPercent, 'odd': u.odd, 'payment': u.payment});
  static Op userUpdate(LUser u) => _op('user.update', {'id': u.id, 'name': u.name, 'username': u.username, 'commissionPercent': u.commissionPercent, 'odd': u.odd, 'payment': u.payment});
  static Op userDelete(String id) => _op('user.delete', {'id': id});
  static Op entryCreate(LEntry e) => _op('entry.create', {'id': e.id, 'userId': e.userId, 'code': e.code, 'mode': e.mode, 'date': e.date, 'createdAt': e.createdAt, 'lines': _ls(e.lines)});
  static Op entryUpdate(String id, List<Line> lines) => _op('entry.update', {'id': id, 'lines': _ls(lines)});
  static Op entryDelete(String id) => _op('entry.delete', {'id': id});
  static Op blockedSet(List<String> numbers) => _op('blocked.set', {'numbers': numbers});
  static Op drawSave(String date, String session, String number) => _op('draw.save', {'date': date, 'session': session, 'number': number});
  static Op drawDelete(String date, String session) => _op('draw.delete', {'date': date, 'session': session});
  static Op coverCreate(String id, String code, double requested, String date) => _op('cover.create', {'id': id, 'code': code, 'requestedAmount': requested, 'date': date});
  static Op coverDelete(String id) => _op('cover.delete', {'id': id});
  static Op finalize(String date, String session, Map<String, String> recordIds) => _op('finalize', {'date': date, 'session': session, 'recordIds': recordIds});
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
      d.users[i] = _userFrom(op);
    case 'user.delete':
      // Vouchers of a deleted user stay (HTML behaviour); the user's history rows keep their name.
      d.users.removeWhere((u) => u.id == op['id']);
    case 'entry.create':
      if (d.entries.any((e) => e.id == op['id'])) return;
      if (!d.users.any((u) => u.id == op['userId'])) throw LedgerRule('USER_NOT_FOUND', 'User not found.');
      final lines = _linesOf(op['lines']);
      for (final l in lines) {
        if (d.blockedNumbers.contains(l.num)) throw LedgerRule('BLOCKED_NUMBER', 'Number ${l.num} is blocked.');
      }
      d.entries.add(LEntry(
        id: op['id'] as String, userId: op['userId'] as String, code: (op['code'] ?? '') as String, mode: op['mode'] as String,
        date: op['date'] as String, createdAt: (op['createdAt'] ?? '') as String, lines: lines));
    case 'entry.update':
      final i = d.entries.indexWhere((e) => e.id == op['id']);
      if (i < 0) throw LedgerRule('ENTRY_NOT_FOUND', 'Voucher not found.');
      d.entries[i] = d.entries[i].withLines(_linesOf(op['lines'])); // like the server: no blocked-number check on edits
    case 'entry.delete':
      d.entries.removeWhere((e) => e.id == op['id']);
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
      final locked = lockedEat(d.coverVouchers);
      if (locked != null && locked != eat) throw LedgerRule('EAT_LOCKED', 'စားငွေကို ပထမကာဘောင်ချာအတိုင်း ${locked.toStringAsFixed(0)} သာ သုံးနိုင်သည်။');
      final plan = buildCoverPlan(numberBalances(d.entries, d.coverVouchers), eat);
      final r = makeCoverVoucher(plan);
      if (r == null) throw LedgerRule('NO_COVER', 'ကာငွေမရှိပါ — သိမ်းရန် ကာမည့်ငွေ မရှိပါ။');
      final seq = d.coverVouchers.fold<int>(0, (m, v) => v.seq > m ? v.seq : m) + 1;
      d.coverVouchers.add(LCover(
        id: op['id'] as String, code: (op['code'] ?? '') as String, seq: seq, requestedAmount: (op['requestedAmount'] as num).toDouble(),
        coverListTotal: r.remainingTotal, date: op['date'] as String, createdAt: DateTime.now().toUtc().toIso8601String(),
        allocations: r.allocations, remainingLines: r.remainingLines));
    case 'cover.delete':
      d.coverVouchers.removeWhere((v) => v.id == op['id']);
    case 'finalize':
      final date = op['date'] as String, session = op['session'] as String;
      final draw = d.drawResults.where((x) => x.date == date && x.session == session).firstOrNull;
      if (draw == null) throw LedgerRule('DRAW_NOT_FOUND', 'No draw result for this date and session.');
      if (d.finalizedRecords.any((r) => r.date == date && r.session == session)) throw LedgerRule('ALREADY_FINALIZED', 'This draw is already finalized.');
      final ids = Map<String, dynamic>.from((op['recordIds'] ?? const {}) as Map);
      final dayEntries = d.entries.where((e) => e.date == date).toList();
      final settled = <String>{};
      final records = <LFinal>[];
      for (final u in d.users) {
        final lines = dayEntries.where((e) => e.userId == u.id).expand((e) => e.lines).toList();
        final s = settleUser(u, lines, draw.number);
        if (s.total == 0) continue; // no stake on this date -> no history row, payment kept
        settled.add(u.id);
        records.add(LFinal(
          id: (ids[u.id] as String?) ?? newUuid(), userId: u.id, userName: u.name, date: date, session: session, number: draw.number,
          total: round2(s.total), winAmount: round2(s.winAmount), odd: s.odd, payout: round2(s.payout), commission: round2(s.commission),
          payment: round2(s.payment), net: round2(s.net), createdAt: DateTime.now().toUtc().toIso8601String()));
      }
      if (records.isEmpty) throw LedgerRule('NOTHING_TO_FINALIZE', 'No commission user has a stake on this date.');
      d.finalizedRecords.addAll(records);
      d.users = d.users.map((u) => settled.contains(u.id) ? u.copyWith(clearPayment: true) : u).toList();
      d.entries.removeWhere((e) => e.date == date);
      d.coverVouchers.clear(); // finalize closes the cover period (the server keeps them, frozen)
    case 'finalized.delete':
      d.finalizedRecords.removeWhere((r) => r.id == op['id']);
    default:
      throw LedgerRule('INVALID_OPERATION', 'Unknown operation $type.');
  }
}

LUser _userFrom(Op op) => LUser(
      id: op['id'] as String, name: op['name'] as String, username: op['username'] as String,
      commissionPercent: (op['commissionPercent'] as num).toDouble(), odd: (op['odd'] as num).toDouble(),
      payment: op['payment'] == null ? null : (op['payment'] as num).toDouble());

List<Line> _linesOf(Object? v) => (v as List).map((x) => Line((x as Map)['num'] as String, (x['amount'] as num).toDouble())).toList();
