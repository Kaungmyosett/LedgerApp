// Plain data classes for the client's ledger. All JSON shapes match backend/src/ledger/snapshot.ts.

double _d(Object? v) => (v as num).toDouble();

class Line {
  const Line(this.num, this.amount);
  final String num;
  final double amount;
  factory Line.fromJson(Map<String, dynamic> j) => Line(j['num'] as String, _d(j['amount']));
  Map<String, dynamic> toJson() => {'num': num, 'amount': amount};
}

List<Line> _lines(Object? v) =>
    ((v ?? const []) as List).map((x) => Line.fromJson(x as Map<String, dynamic>)).toList();

enum SettlementSchedule { daily, weekly }

class LUser {
  const LUser({required this.id, required this.name, required this.username, required this.commissionPercent, required this.odd, this.payment, this.settlementSchedule = SettlementSchedule.daily, this.hasFinalizedVouchers = false});
  final String id;
  final String name;
  final String username;
  final double commissionPercent;
  final double odd;
  final double? payment;
  final SettlementSchedule settlementSchedule;
  final bool hasFinalizedVouchers;

  LUser copyWith({String? name, String? username, double? commissionPercent, double? odd, double? payment, bool clearPayment = false, bool? hasFinalizedVouchers}) => LUser(
        id: id,
        name: name ?? this.name,
        username: username ?? this.username,
        commissionPercent: commissionPercent ?? this.commissionPercent,
        odd: odd ?? this.odd,
        payment: clearPayment ? null : (payment ?? this.payment),
        settlementSchedule: settlementSchedule,
        hasFinalizedVouchers: hasFinalizedVouchers ?? this.hasFinalizedVouchers,
      );

  factory LUser.fromJson(Map<String, dynamic> j) => LUser(
        id: j['id'] as String,
        name: j['name'] as String,
        username: j['username'] as String,
        commissionPercent: _d(j['commissionPercent']),
        odd: _d(j['odd']),
        payment: j['payment'] == null ? null : _d(j['payment']),
        hasFinalizedVouchers: j['hasFinalizedVouchers'] == true,
        settlementSchedule: j['settlementSchedule'] == 'weekly'
            ? SettlementSchedule.weekly
            : SettlementSchedule.daily,
      );
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'username': username, 'commissionPercent': commissionPercent, 'odd': odd, 'payment': payment, 'settlementSchedule': settlementSchedule.name, 'hasFinalizedVouchers': hasFinalizedVouchers};
}

class LEntry {
  const LEntry({required this.id, required this.userId, required this.code, required this.mode, required this.date, required this.createdAt, required this.lines, this.session});
  final String id;
  final String userId;
  final String code;
  final String mode; // 'format' | 'manual'
  final String date; // YYYY-MM-DD
  final String createdAt;
  final String? session;
  final List<Line> lines;

  double get total => lines.fold(0.0, (a, x) => a + x.amount);
  LEntry withLines(List<Line> l) => LEntry(id: id, userId: userId, code: code, mode: mode, date: date, createdAt: createdAt, lines: l, session: session);

  factory LEntry.fromJson(Map<String, dynamic> j) => LEntry(
        id: j['id'] as String,
        userId: j['userId'] as String,
        code: (j['code'] ?? '') as String,
        mode: (j['mode'] ?? 'manual') as String,
        date: j['date'] as String,
        createdAt: (j['createdAt'] ?? '') as String,
        session: j['session'] as String?,
        lines: _lines(j['lines']),
      );
  Map<String, dynamic> toJson() => {
        'id': id, 'userId': userId, 'code': code, 'mode': mode, 'date': date, 'createdAt': createdAt, 'session': session,
        'lines': lines.map((x) => x.toJson()).toList(),
      };
}

class LDraw {
  const LDraw({required this.date, required this.session, required this.number, this.enteredAt = ''});
  final String date;
  final String session; // 'morning' | 'evening'
  final String number;
  final String enteredAt;
  factory LDraw.fromJson(Map<String, dynamic> j) => LDraw(
        date: j['date'] as String, session: j['session'] as String, number: j['number'] as String, enteredAt: (j['enteredAt'] ?? '') as String);
  Map<String, dynamic> toJson() => {'date': date, 'session': session, 'number': number, 'enteredAt': enteredAt};
}

class LCover {
  const LCover({
    required this.id, required this.code, required this.seq, required this.requestedAmount, required this.coverListTotal,
    required this.date, required this.createdAt, required this.allocations, required this.remainingLines, this.session,
  });
  final String id;
  final String code;
  final int seq;
  final double requestedAmount;
  final double coverListTotal;
  final String date;
  final String createdAt;
  final String? session;
  final List<Line> allocations;
  final List<Line> remainingLines;

  factory LCover.fromJson(Map<String, dynamic> j) => LCover(
        id: j['id'] as String,
        code: (j['code'] ?? '') as String,
        seq: (j['seq'] as num).toInt(),
        requestedAmount: _d(j['requestedAmount']),
        coverListTotal: _d(j['coverListTotal']),
        date: (j['date'] ?? '') as String,
        createdAt: (j['createdAt'] ?? '') as String,
        session: j['session'] as String?,
        allocations: _lines(j['allocations']),
        remainingLines: _lines(j['remainingLines']),
      );
  Map<String, dynamic> toJson() => {
        'id': id, 'code': code, 'seq': seq, 'requestedAmount': requestedAmount, 'coverListTotal': coverListTotal,
        'date': date, 'createdAt': createdAt, 'session': session,
        'allocations': allocations.map((x) => x.toJson()).toList(),
        'remainingLines': remainingLines.map((x) => x.toJson()).toList(),
      };
}

class LFinal {
  const LFinal({
    required this.id, required this.userId, required this.userName, required this.date, required this.session, required this.number,
    required this.total, required this.winAmount, required this.odd, required this.payout, required this.commission,
    required this.payment, required this.net, required this.createdAt,
    this.eaten, this.covered,
  });
  final String id, userId, userName, date, session, number, createdAt;
  final double total, winAmount, odd, payout, commission, payment, net;
  final double? eaten, covered;
  factory LFinal.fromJson(Map<String, dynamic> j) => LFinal(
        id: j['id'] as String,
        userId: (j['userId'] ?? '') as String,
        userName: (j['userName'] ?? '') as String,
        date: j['date'] as String,
        session: j['session'] as String,
        number: j['number'] as String,
        total: _d(j['total']), winAmount: _d(j['winAmount']), odd: _d(j['odd']), payout: _d(j['payout']),
        commission: _d(j['commission']), payment: _d(j['payment']), net: _d(j['net']),
        eaten: (j['eaten'] as num?)?.toDouble(), covered: (j['covered'] as num?)?.toDouble(),
        createdAt: (j['createdAt'] ?? '') as String,
      );
  Map<String, dynamic> toJson() => {
        'id': id, 'userId': userId, 'userName': userName, 'date': date, 'session': session, 'number': number,
        'total': total, 'winAmount': winAmount, 'odd': odd, 'payout': payout, 'commission': commission,
        'payment': payment, 'net': net, 'createdAt': createdAt,
      };
}

class LDebtEntry {
  const LDebtEntry({
    required this.id,
    required this.userId,
    required this.userName,
    required this.date,
    required this.kind,
    required this.amount,
    required this.createdAt,
    this.session,
  });

  final String id, userId, userName, date, kind, createdAt;
  final double amount;
  final String? session;

  int get changeCents => (amount * 100).round() * (kind == 'repayment' ? -1 : 1);

  factory LDebtEntry.fromJson(Map<String, dynamic> json) {
    final session = json['session'] as String?;
    final kind = json['kind'] as String;
    final amount = _d(json['amount']);
    return LDebtEntry(
      id: json['id'] as String,
      userId: json['userId'] as String,
      userName: json['userName'] as String,
      date: json['date'] as String,
      kind: session == null ? kind : 'settlement',
      amount: session != null && kind == 'repayment' ? -amount : amount,
      createdAt: json['createdAt'] as String,
      session: session,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id, 'userId': userId, 'userName': userName, 'date': date,
    'kind': kind, 'amount': amount, 'createdAt': createdAt, 'session': session,
  };
}

class LBlockedLine {
  const LBlockedLine({
    required this.opId, required this.userId, required this.userName,
    required this.num, required this.amount, required this.createdAt,
  });

  final String opId, userId, userName, num, createdAt;
  final double amount;

  factory LBlockedLine.fromJson(Map<String, dynamic> json) => LBlockedLine(
    opId: json['opId'] as String, userId: json['userId'] as String,
    userName: json['userName'] as String, num: json['num'] as String,
    amount: _d(json['amount']), createdAt: json['createdAt'] as String,
  );

  Map<String, dynamic> toJson() => {
    'opId': opId, 'userId': userId, 'userName': userName, 'num': num,
    'amount': amount, 'createdAt': createdAt,
  };
}

/// The whole ledger of one client. Replaced as a unit by a server snapshot; changed locally by [applyOpLocally].
class LedgerData {
  LedgerData({
    List<LUser>? users, List<LEntry>? entries, List<String>? blockedNumbers, List<LDraw>? drawResults,
    List<LCover>? coverVouchers, List<LFinal>? finalizedRecords,
    List<LDebtEntry>? debtEntries, List<LBlockedLine>? blockedLog, this.serverTime = '',
  })  : users = users ?? [],
        entries = entries ?? [],
        blockedNumbers = blockedNumbers ?? [],
        drawResults = drawResults ?? [],
        coverVouchers = coverVouchers ?? [],
        finalizedRecords = finalizedRecords ?? [],
        debtEntries = debtEntries ?? [],
        blockedLog = blockedLog ?? [];

  List<LUser> users;
  List<LEntry> entries;
  List<String> blockedNumbers;
  List<LDraw> drawResults;
  List<LCover> coverVouchers;
  List<LFinal> finalizedRecords;
  List<LDebtEntry> debtEntries;
  List<LBlockedLine> blockedLog;
  String serverTime;

  /// Outstanding balances by account, in cents. A negative balance is owed by the dealer.
  Map<String, int> get debtBalances {
    final balances = <String, int>{};
    for (final entry in debtEntries) {
      balances.update(entry.userId, (total) => total + entry.changeCents,
          ifAbsent: () => entry.changeCents);
    }
    return balances;
  }

  factory LedgerData.fromJson(Map<String, dynamic> j) {
    List<T> list<T>(String k, T Function(Map<String, dynamic>) f) =>
        ((j[k] ?? const []) as List).map((x) => f(x as Map<String, dynamic>)).toList();
    return LedgerData(
      users: list('users', LUser.fromJson),
      entries: list('entries', LEntry.fromJson),
      blockedNumbers: ((j['blockedNumbers'] ?? const []) as List).map((x) => x as String).toList(),
      drawResults: list('drawResults', LDraw.fromJson),
      coverVouchers: list('coverVouchers', LCover.fromJson),
      finalizedRecords: list('finalizedRecords', LFinal.fromJson),
      debtEntries: list('debtEntries', LDebtEntry.fromJson),
      blockedLog: list('blockedLog', LBlockedLine.fromJson),
      serverTime: (j['serverTime'] ?? '') as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'serverTime': serverTime,
        'users': users.map((x) => x.toJson()).toList(),
        'entries': entries.map((x) => x.toJson()).toList(),
        'blockedNumbers': blockedNumbers,
        'drawResults': drawResults.map((x) => x.toJson()).toList(),
        'coverVouchers': coverVouchers.map((x) => x.toJson()).toList(),
        'debtEntries': debtEntries.map((x) => x.toJson()).toList(),
        'blockedLog': blockedLog.map((x) => x.toJson()).toList(),
        'finalizedRecords': finalizedRecords.map((x) => x.toJson()).toList(),
      };

  /// Deep copy via JSON (small data; keeps the reducer free of aliasing bugs).
  LedgerData copy() => LedgerData.fromJson(toJson());
}
