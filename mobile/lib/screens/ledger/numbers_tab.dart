import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/lang.dart';
import '../../ledger/draw_period.dart';
import '../../ledger/ledger_store.dart';
import '../../ledger/logic.dart';
import 'common.dart';

/// Numbers 00–99 page: totals, the "Active" counter (numbers whose stake is not 0) and the grid.
class NumbersTab extends StatelessWidget {
  const NumbersTab({super.key});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<LedgerStore>().data;
    final period = context.watch<DrawPeriod?>() ?? drawPeriodAt(DateTime.now());
    final entries = d.entriesFor(period);
    final draw = d.drawFor(period);
    final result = draw == null || entries.isEmpty
        ? null
        : numbersSummary(d.users, entries, d.coversFor(period), [draw]);
    final s = numbersSummary(d.users, d.entries, d.coverVouchers, []);
    final winning = result?.winning ?? '';
    final cs = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(12), children: [
      Card(
        color: cs.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(context.t('num.active', {'n': s.activeCount}), style: Theme.of(context).textTheme.titleLarge?.copyWith(color: cs.onPrimaryContainer)),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(children: [
            KV(context.t('num.totalGross'), money(s.totalGross)),
            KV(context.t('num.totalEaten'), money(s.totalEaten)),
            KV(context.t('num.totalCover'), money(s.totalCover)),
            if (result != null) ...[
              const Divider(),
              KV(context.t('num.winning'), winning, bold: true),
              KV(context.t('num.winGross'), money(result.winGross)),
              // Your eaten: + green (you gain), - red. Other dealer cover: + red (you pay), - green.
              KV(context.t('num.yourEaten'), money(result.yourEaten), bold: true, color: _sign(result.yourEaten, positiveGood: true)),
              KV(context.t('num.otherCover'), money(result.otherDealerCover), bold: true, color: _sign(result.otherDealerCover, positiveGood: false)),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Text(context.t('num.legend'), style: const TextStyle(fontSize: 12)),
      const SizedBox(height: 8),
      GridView.count(
        crossAxisCount: 5,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        mainAxisExtent: 70,
        children: [
          for (var i = 0; i < 100; i++) _cell(context, i.toString().padLeft(2, '0'), s, d.blockedNumbers, winning),
        ],
      ),
    ]);
  }

  static Color? _sign(double v, {required bool positiveGood}) {
    if (v == 0) return null;
    final good = Colors.green.shade700, bad = Colors.red.shade700;
    return (v > 0) == positiveGood ? good : bad;
  }

  Widget _cell(BuildContext context, String n, NumbersSummary s, List<String> blocked, String winning) {
    final cs = Theme.of(context).colorScheme;
    final b = s.balances[n]!;
    final isBlocked = blocked.contains(n);
    final isWin = winning.isNotEmpty && n == winning;
    final active = b.gross > 0;
    final hasAllocations = b.cover > 0 || b.covered > 0;
    final foreground = isBlocked
        ? cs.onErrorContainer
        : isWin
            ? Colors.black87
            : active
                ? cs.onSecondaryContainer
                : cs.onSurface;
    Widget amount(String text) => FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(text, style: const TextStyle(fontSize: 11)),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
      decoration: BoxDecoration(
        color: isBlocked ? cs.errorContainer : isWin ? Colors.amber.shade200 : active ? cs.secondaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: isWin ? Border.all(color: Colors.amber.shade800, width: 2) : null,
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: foreground),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(n, style: const TextStyle(fontWeight: FontWeight.bold)))),
          if (hasAllocations) ...[
            Flexible(child: amount(context.t('num.coverCell', {'v': money(b.cover)}))),
            Flexible(child: amount(context.t('num.eatCell', {'v': money(b.covered)}))),
          ] else if (active)
            Flexible(child: amount(money(b.gross))),
        ]),
      ),
    );
  }
}
