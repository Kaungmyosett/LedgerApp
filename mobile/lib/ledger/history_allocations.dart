import 'logic.dart';
import 'models.dart';

typedef HistoryAllocation = ({double eaten, double covered});

/// Shares the frozen cover amounts by each settled user's stake on that number.
Map<String, HistoryAllocation> historyAllocations(
  Iterable<LEntry> entries,
  List<LCover> covers,
) {
  final stakesByNumber = <String, Map<String, BigInt>>{};
  for (final entry in entries) {
    for (final line in entry.lines) {
      final stakes = stakesByNumber.putIfAbsent(line.num, () => {});
      stakes.update(entry.userId, (cents) => cents + _cents(line.amount),
          ifAbsent: () => _cents(line.amount));
    }
  }

  final balances = numberBalances([], covers);
  final eaten = <String, BigInt>{};
  final covered = <String, BigInt>{};
  for (final MapEntry(key: number, value: stakes) in stakesByNumber.entries) {
    final total = stakes.values.fold(BigInt.zero, (sum, stake) => sum + stake);
    if (total == BigInt.zero) continue;
    final balance = balances[number]!;
    _allocate(_cents(balance.covered), stakes, total, eaten);
    _allocate(_cents(balance.cover), stakes, total, covered);
  }
  return {
    for (final id in {...eaten.keys, ...covered.keys})
      id: (
        eaten: (eaten[id] ?? BigInt.zero).toDouble() / 100,
        covered: (covered[id] ?? BigInt.zero).toDouble() / 100,
      ),
  };
}

BigInt _cents(double amount) => BigInt.from((amount * 100).round());

void _allocate(
  BigInt amount,
  Map<String, BigInt> stakes,
  BigInt total,
  Map<String, BigInt> allocated,
) {
  if (amount == BigInt.zero) return;
  final shares = [
    for (final MapEntry(key: id, value: stake) in stakes.entries)
      (id: id, cents: (amount * stake) ~/ total, remainder: (amount * stake) % total),
  ]..sort((a, b) {
      final remainder = b.remainder.compareTo(a.remainder);
      return remainder != 0 ? remainder : a.id.compareTo(b.id);
    });
  final base = shares.fold(BigInt.zero, (sum, share) => sum + share.cents);
  final leftover = (amount - base).toInt();
  for (final (index, share) in shares.indexed) {
    final cents = share.cents + (index < leftover ? BigInt.one : BigInt.zero);
    allocated.update(share.id, (sum) => sum + cents, ifAbsent: () => cents);
  }
}
