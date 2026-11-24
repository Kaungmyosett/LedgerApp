// Pure ledger rules, ported 1:1 from backend/src/ledger/logic.ts (which is verified against ledger_v31.html).
// Same operations in the same order on purpose, so floating-point results are identical.
// test/ledger_logic_test.dart checks this file against golden values produced by the real HTML.
import 'models.dart';

/// Round to 2 decimals, half away from zero (same as the server).
double round2(double x) {
  final s = x < 0 ? -1.0 : 1.0;
  return s * (x.abs() * 100).round() / 100;
}

String pad2(Object? n) => (n ?? '').toString().trim().padLeft(2, '0');
String _n2(int i) => i.toString().padLeft(2, '0');

const _brother = <int, List<int>>{
  0: [0, 19, 28, 37, 46, 55, 64, 73, 82, 91], 1: [1, 10, 29, 38, 47, 56, 65, 74, 83, 92],
  2: [2, 11, 20, 39, 48, 57, 66, 75, 84, 93], 3: [3, 12, 21, 30, 49, 58, 67, 76, 85, 94],
  4: [4, 13, 22, 31, 40, 59, 68, 77, 86, 95], 5: [5, 14, 23, 32, 41, 50, 69, 78, 87, 96],
  6: [6, 15, 24, 33, 42, 51, 60, 79, 88, 97], 7: [7, 16, 25, 34, 43, 52, 61, 70, 89, 98],
  8: [8, 17, 26, 35, 44, 53, 62, 71, 80, 99], 9: [9, 18, 27, 36, 45, 54, 63, 72, 81, 90],
};
const _special = <String, List<int>>{
  'apu': [0, 11, 22, 33, 44, 55, 66, 77, 88, 99],
  'nyiko': [12, 21, 23, 32, 34, 43, 45, 54, 56, 65, 67, 76, 78, 87, 89, 98, 90, 9, 1, 10],
  'power': [5, 16, 27, 38, 49, 50, 61, 72, 83, 94],
  'natkat': [7, 18, 24, 35, 69, 70, 81, 42, 53, 96],
};

// v0.6.7: "Apu-1000", "Apu=1000" and "Apu1000" mean the same as "Apu 1000".
final _reSpecial = RegExp(r'^(Apu|Nyiko|Power|Natkat)\s*[-=]?\s*(\d+)$', caseSensitive: false);
// v0.6.7: "=" works like "-" here too ("1PP=100", "17=R2500", "17R=2500").
// v0.6.8 ခွေ / ခွေပူး: "012 KHWE 1000" after normalizing.
final _reKhwe = RegExp(r'^(\d{2,20})\s*(KHWEPU|KHWE)\s*[-=]?\s*(\d+)$', caseSensitive: false);
final _rePat = RegExp(r'^(\d{1,2})\s*(PP|TO|BO|BK)\s*[-=]?\s*(\d+)$', caseSensitive: false);
final _reDash = RegExp(r'^([\d/]+)\s*-\s*(\d+)$');
final _reDash1 = RegExp(r'^(\d{1,2})\s*-\s*(\d+)$');
final _reR = RegExp(r'^([\d/]+)\s*[-=]?\s*R\s*[-=]?\s*(\d+)$', caseSensitive: false);
final _reSpace = RegExp(r'^([\d/]+)\s+(\d+)$');
final _reEq = RegExp(r'^([\d/]+)\s*=\s*(\d+)$');
final _re12 = RegExp(r'^\d{1,2}$');
final _reNum2 = RegExp(r'^[0-9]{1,2}$');

class ParseResult {
  ParseResult(this.result, this.errors);
  final List<Line> result;
  final List<String> errors;
}

// v0.6.7: Myanmar words accepted in the Format box (owner's list; same as logic.ts).
// Tall-aa (U+102B) is treated like aa (U+102C).
final _myWords = <(RegExp, String)>[
  (RegExp('\u1001\u103d\u1031\u1015\u1030\u1038'), 'KHWEPU'), // ခွေပူး (before ခွေ)
  (RegExp('\u1001\u103d\u1031'), 'KHWE'), // ခွေ
  (RegExp('\u100a\u102e\u1000\u102d\u102f'), 'Nyiko'), // ညီကို
  (RegExp('\u1015\u102c\u101d\u102c'), 'Power'), // ပါဝါ
  (RegExp('\u1014\u1000\u1039\u1001\u1010\u103a'), 'Natkat'), // နက္ခတ်
  (RegExp('\u1021\u1015\u1030\u1038'), 'Apu'), // အပူး
  (RegExp('\u1015\u102c\u1010\u103a'), 'PP'), // ပါတ်
  (RegExp('\u1011\u102d\u1015\u103a'), 'TO'), // ထိပ်
  (RegExp('\u1015\u102d\u1010\u103a'), 'BO'), // ပိတ်
];

/// Myanmar words -> Latin keywords ("3ပါတ်200" -> "3 PP 200", "အပူး 1000" -> "Apu 1000").
String normalizeFormatLine(String line) {
  var s = line.replaceAll('\u102b', '\u102c');
  for (final (re, en) in _myWords) {
    s = s.replaceAll(re, ' $en ');
  }
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

ParseResult parseFormat(String raw) {
  final bets = <Line>[];
  final errors = <String>[];
  void add(int num, double amount) {
    if (num >= 0 && num <= 99 && amount.isFinite && amount > 0) bets.add(Line(_n2(num), amount));
  }

  bool badNums(List<String> nums, RegExp re) => nums.any((n) => !re.hasMatch(n) || int.parse(n) > 99);

  final lines = raw.replaceAll('\r', '\n').split(RegExp(r'[\n,;]+')).map((x) => x.trim()).where((x) => x.isNotEmpty);
  for (final original in lines) {
    final line = normalizeFormatLine(original);
    RegExpMatch? m;
    if ((m = _reSpecial.firstMatch(line)) != null) {
      final amt = double.parse(m!.group(2)!);
      for (final n in _special[m.group(1)!.toLowerCase()]!) {
        add(n, amt);
      }
      continue;
    }
    if ((m = _reKhwe.firstMatch(line)) != null) {
      // Every pair of two different digits (012 -> 01/02/10/12/20/21); ခွေပူး adds 00/11/22.
      final digits = m!.group(1)!.split('').map(int.parse).toSet().toList();
      final amount = double.parse(m.group(3)!);
      if (digits.length < 2) {
        errors.add('ခွေ တွင် မတူသော digit ၂ လုံးနှင့်အထက် လိုသည်: $original');
        continue;
      }
      for (final a in digits) {
        for (final b in digits) {
          if (a != b) add(a * 10 + b, amount);
        }
      }
      if (m.group(2)!.toUpperCase() == 'KHWEPU') {
        for (final a in digits) {
          add(a * 11, amount);
        }
      }
      continue;
    }
    if ((m = _rePat.firstMatch(line)) != null) {
      final digit = int.parse(m!.group(1)!);
      final kind = m.group(2)!.toUpperCase();
      final amount = double.parse(m.group(3)!);
      if (digit > 9) {
        errors.add('PP / TO / BO / BR တွင် 0 မှ 9 အထိ digit သာသုံးပါ: $original');
        continue;
      }
      if (kind == 'PP') {
        for (var i = 0; i < 10; i++) {
          add(digit * 10 + i, amount);
          if (i != digit) add(i * 10 + digit, amount); // 1PP: 11 once
        }
      } else if (kind == 'TO') {
        for (var i = 0; i < 10; i++) {
          add(digit * 10 + i, amount);
        }
      } else if (kind == 'BO') {
        for (var i = 0; i < 10; i++) {
          add(i * 10 + digit, amount);
        }
      } else {
        for (final n in _brother[digit]!) {
          add(n, amount);
        }
      }
      continue;
    }
    if ((m = _reDash.firstMatch(line)) != null) {
      final amount = double.parse(m!.group(2)!);
      final nums = m.group(1)!.split('/');
      if (badNums(nums, _reNum2) || amount <= 0) {
        errors.add('ဂဏန်း သို့မဟုတ် ငွေပမာဏ မမှန်ပါ: $original');
        continue;
      }
      for (final n in nums) {
        add(int.parse(n), amount);
      }
      continue;
    }
    if ((m = _reDash1.firstMatch(line)) != null) {
      final num = int.parse(m!.group(1)!);
      final amt = double.parse(m.group(2)!);
      if (num <= 99 && amt > 0) {
        add(num, amt);
      } else {
        errors.add('ဂဏန်း သို့မဟုတ် ငွေပမာဏ မမှန်ပါ: $original');
      }
      continue;
    }
    if ((m = _reR.firstMatch(line)) != null) {
      final amount = double.parse(m!.group(2)!);
      final nums = m.group(1)!.split('/');
      if (badNums(nums, _re12)) {
        errors.add('ဂဏန်း format မမှန်ပါ: $original');
        continue;
      }
      for (final n in nums) {
        final v = int.parse(n);
        final r = int.parse(_n2(v).split('').reversed.join());
        add(v, amount);
        if (r != v) add(r, amount); // 00 R: 00 once
      }
      continue;
    }
    if ((m = _reSpace.firstMatch(line)) != null || (m = _reEq.firstMatch(line)) != null) {
      final amount = double.parse(m!.group(2)!);
      final nums = m.group(1)!.split('/');
      if (badNums(nums, _re12)) {
        errors.add('ဂဏန်း format မမှန်ပါ: $original');
        continue;
      }
      for (final n in nums) {
        add(int.parse(n), amount);
      }
      continue;
    }
    errors.add('Format မမှန်ပါ: $original');
  }
  // Merge duplicates, keeping first-seen order (same as a JS Map).
  final merged = <String, double>{};
  for (final x in bets) {
    merged[x.num] = (merged[x.num] ?? 0) + x.amount;
  }
  return ParseResult(merged.entries.map((e) => Line(e.key, e.value)).toList(), errors);
}

List<String> parseBlockedNumbers(String raw) {
  final out = <String>{};
  for (final x in raw.split(RegExp(r'[\s,;/]+')).where((x) => x.isNotEmpty)) {
    if (_re12.hasMatch(x) && int.parse(x) <= 99) out.add(x.padLeft(2, '0'));
  }
  final l = out.toList()..sort((a, b) => int.parse(a).compareTo(int.parse(b)));
  return l;
}

// ------------------------------------------------------------------ Numbers / cover
// Cover rule (v0.6.1, the owner's rule; same as logic.ts):
//  * The first cover voucher of a period fixes "eat per number" (E); later vouchers must use the same E
//    until every active cover voucher is deleted or the period is finalized.
//  * Per number: eat now = max(0, min(g, E) - eaten so far); cover now = max(0, max(0, g - E) - covered so far).
//  * A voucher with nothing to cover is refused ("ကာငွေမရှိပါ").
class Balance {
  const Balance(this.gross, this.covered, this.cover, this.remaining);
  /// covered = eaten so far, cover = sent to other dealers so far, remaining = not handled yet.
  final double gross, covered, cover, remaining;
}

final _re2d = RegExp(r'^\d{2}$');
double _pos(double v) => v > 0 ? v : 0;

/// [covers] must be the active cover vouchers, [entries] only active (not finalized) vouchers.
Map<String, Balance> numberBalances(List<LEntry> entries, List<LCover> covers) {
  final gross = <String, double>{}, eaten = <String, double>{}, cover = <String, double>{};
  void addTo(Map<String, double> m, Line x) {
    final n = pad2(x.num);
    if (_re2d.hasMatch(n)) m[n] = (m[n] ?? 0) + _pos(x.amount);
  }

  for (final e in entries) {
    for (final x in e.lines) {
      addTo(gross, x);
    }
  }
  for (final v in covers) {
    for (final x in v.allocations) {
      addTo(eaten, x);
    }
    for (final x in v.remainingLines) {
      addTo(cover, x);
    }
  }
  final out = <String, Balance>{};
  for (var i = 0; i < 100; i++) {
    final n = _n2(i);
    final g = gross[n] ?? 0, e = eaten[n] ?? 0, c = cover[n] ?? 0;
    out[n] = Balance(g, e, c, _pos(g - e - c));
  }
  return out;
}

/// The fixed eat-per-number of the current period, or null when there is no active cover voucher.
double? lockedEat(List<LCover> covers) {
  if (covers.isEmpty) return null;
  final sorted = [...covers]..sort((a, b) => a.seq.compareTo(b.seq));
  return sorted.first.requestedAmount;
}

class CoverPlan {
  CoverPlan(this.eatPerNumber, this.eat, this.cover, this.eatTotal, this.coverTotal);
  final double eatPerNumber;
  final List<Line> eat, cover;
  final double eatTotal, coverTotal;
}

CoverPlan buildCoverPlan(Map<String, Balance> balances, double eatPerNumber) {
  final eat = <Line>[], cover = <Line>[];
  for (var i = 0; i < 100; i++) {
    final num = _n2(i);
    final b = balances[num]!;
    if (b.gross <= 0) continue;
    final e = _pos((b.gross < eatPerNumber ? b.gross : eatPerNumber) - b.covered);
    final c = _pos(_pos(b.gross - eatPerNumber) - b.cover);
    if (e > 0) eat.add(Line(num, e));
    if (c > 0) cover.add(Line(num, c));
  }
  double sum(List<Line> l) => l.fold(0.0, (a, x) => a + x.amount);
  return CoverPlan(eatPerNumber, eat, cover, sum(eat), sum(cover));
}

class CoverResult {
  CoverResult(this.allocations, this.remainingLines, this.remainingTotal);
  /// allocations = eaten by this voucher; remainingLines = this voucher's cover list.
  final List<Line> allocations, remainingLines;
  final double remainingTotal;
}

/// Null when nothing can be covered ("ကာငွေမရှိပါ").
CoverResult? makeCoverVoucher(CoverPlan plan) {
  if (plan.coverTotal <= 0) return null;
  return CoverResult(plan.eat, plan.cover, plan.coverTotal);
}

// ------------------------------------------------------------------ Settlement
class Settlement {
  Settlement(this.total, this.winAmount, this.odd, this.payout, this.commissionPercent, this.commission, this.payment, this.net);
  final double total, winAmount, odd, payout, commissionPercent, commission, payment, net;
}

Settlement settleUser(LUser user, List<Line> lines, String winning) {
  final total = lines.fold(0.0, (a, x) => a + x.amount);
  final winAmount = winning.isNotEmpty ? lines.where((x) => pad2(x.num) == winning).fold(0.0, (a, x) => a + x.amount) : 0.0;
  final odd = user.odd;
  final payout = winAmount * odd;
  final commission = (total * user.commissionPercent) / 100;
  final payment = user.payment ?? 0;
  final net = total - payout - commission - payment;
  return Settlement(total, winAmount, odd, payout, user.commissionPercent, commission, payment, net);
}

// ------------------------------------------------------------------ Draws
/// Latest first: newest date, and on the same date evening before morning.
List<LDraw> sortDraws(List<LDraw> draws) {
  final l = draws.where((x) => x.number.isNotEmpty).toList();
  l.sort((a, b) {
    final c = b.date.compareTo(a.date);
    if (c != 0) return c;
    return (b.session == 'evening' ? 1 : 0) - (a.session == 'evening' ? 1 : 0);
  });
  return l;
}

// ------------------------------------------------------------------ Numbers page summary
class NumbersSummary {
  NumbersSummary({
    required this.balances, required this.totalGross, required this.totalEaten, required this.totalCover, required this.activeCount,
    required this.winning, required this.winGross, required this.avgOdd, required this.avgWinnerCommission,
    required this.yourEaten, required this.otherDealerCover,
  });
  final Map<String, Balance> balances;
  final double totalGross, totalEaten, totalCover, winGross, avgOdd, avgWinnerCommission, yourEaten, otherDealerCover;
  final int activeCount;
  final String winning;
}

NumbersSummary numbersSummary(List<LUser> users, List<LEntry> entries, List<LCover> covers, List<LDraw> draws) {
  final balances = numberBalances(entries, covers);
  final sorted = sortDraws(draws);
  final winning = sorted.isEmpty ? '' : sorted.first.number.padLeft(2, '0');
  var totalGross = 0.0, totalEaten = 0.0, totalCover = 0.0;
  for (final x in balances.values) {
    totalGross += x.gross;
    totalEaten += x.covered;
    totalCover += x.cover;
  }
  final activeCount = balances.values.where((x) => x.gross > 0).length;
  final winBalance = winning.isNotEmpty ? balances[winning]! : const Balance(0, 0, 0, 0);
  final winUsers = <({double stake, double odd, double commission})>[];
  if (winning.isNotEmpty) {
    for (final u in users) {
      final stake = entries
          .where((e) => e.userId == u.id)
          .expand((e) => e.lines)
          .where((x) => pad2(x.num) == winning)
          .fold(0.0, (s, x) => s + _pos(x.amount));
      if (stake > 0) winUsers.add((stake: stake, odd: u.odd, commission: u.commissionPercent));
    }
  }
  final winUserStake = winUsers.fold(0.0, (a, x) => a + x.stake);
  final avgOdd = winUserStake != 0 ? winUsers.fold(0.0, (a, x) => a + x.stake * x.odd) / winUserStake : 0.0;
  final avgWinnerCommission = winUsers.isNotEmpty ? winUsers.fold(0.0, (a, x) => a + x.commission) / winUsers.length : 0.0;
  final otherDealerCover = totalCover - (totalCover * 0.13) - (avgOdd * winBalance.cover);
  // v0.6.6 (owner's rule): with nothing covered to other dealers you eat the whole stake,
  // so "your eaten" uses the total stake (and the full stake on the winning number).
  // Computed per commission user: total stake - (their stake x their commission %) - (their winning stake x their odd).
  double yourEaten;
  if (totalCover == 0) {
    var commission = 0.0, payout = 0.0;
    for (final u in users) {
      final lines = entries.where((e) => e.userId == u.id).expand((e) => e.lines).toList();
      final stake = lines.fold(0.0, (a, x) => a + _pos(x.amount));
      final win = winning.isNotEmpty ? lines.where((x) => pad2(x.num) == winning).fold(0.0, (a, x) => a + _pos(x.amount)) : 0.0;
      commission += stake * u.commissionPercent / 100;
      payout += win * u.odd;
    }
    yourEaten = totalGross - commission - payout;
  } else {
    yourEaten = totalEaten - (avgWinnerCommission / 100 * totalEaten) - (avgOdd * winBalance.covered);
  }
  return NumbersSummary(
    balances: balances, totalGross: totalGross, totalEaten: totalEaten, totalCover: totalCover, activeCount: activeCount,
    winning: winning, winGross: winBalance.gross, avgOdd: avgOdd, avgWinnerCommission: avgWinnerCommission,
    yourEaten: yourEaten, otherDealerCover: otherDealerCover,
  );
}
