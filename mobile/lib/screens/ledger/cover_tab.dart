import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../i18n/lang.dart';
import '../../ledger/ledger_store.dart';
import '../../ledger/logic.dart';
import '../../ledger/models.dart';
import '../../ledger/ops.dart';
import 'common.dart';

/// Cover page. The first voucher fixes "eat per number"; later vouchers use the same amount and list only
/// the cover that changed since the previous vouchers (new stakes). Finalize starts a new period.
class CoverTab extends StatefulWidget {
  const CoverTab({super.key});
  @override
  State<CoverTab> createState() => _CoverTabState();
}

class _CoverTabState extends State<CoverTab> {
  final _amount = TextEditingController();
  String? _error;

  double? _eat(double? locked) {
    if (locked != null) return locked;
    final v = parseAmount(_amount.text);
    if (v == null || v != v.roundToDouble()) return null;
    return v;
  }

  Future<void> _save(double eat) async {
    final store = context.read<LedgerStore>();
    try {
      await store.run(Ops.coverCreate(newUuid(), newVoucherCode('C'), eat, today()));
      setState(() => _error = null);
      if (mounted) toast(context, context.t('cover.saved'));
    } on LedgerRule catch (e) {
      setState(() => _error = trRule(context, e.code, e.message));
    }
  }

  double _sum(List<Line> l) => l.fold(0.0, (a, x) => a + x.amount);

  Widget _chips(List<Line> l) => Wrap(spacing: 4, runSpacing: 2, children: [
        for (final x in l) Chip(visualDensity: VisualDensity.compact, label: Text('${x.num}=${money(x.amount)}', style: const TextStyle(fontSize: 11))),
      ]);

  @override
  Widget build(BuildContext context) {
    final d = context.watch<LedgerStore>().data;
    final locked = lockedEat(d.coverVouchers);
    if (locked != null && _amount.text != money(locked).replaceAll(',', '')) _amount.text = money(locked).replaceAll(',', '');
    final eat = _eat(locked);
    final plan = eat == null ? null : buildCoverPlan(numberBalances(d.entries, d.coverVouchers), eat);
    final result = plan == null ? null : makeCoverVoucher(plan);
    final covers = [...d.coverVouchers]..sort((a, b) => b.seq.compareTo(a.seq));
    final err = Theme.of(context).colorScheme.error;

    return ListView(padding: const EdgeInsets.all(12), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('cover.title'), style: Theme.of(context).textTheme.titleMedium),
            TextField(
              controller: _amount,
              enabled: locked == null,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.t('cover.eat'),
                helperText: context.t(locked == null ? 'cover.eatHelp' : 'cover.eatLocked'),
                helperMaxLines: 2,
                suffixIcon: locked == null ? null : const Icon(Icons.lock_outline),
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            if (plan != null) ...[
              const SizedBox(height: 10),
              Text(context.t('cover.eatNow', {'v': money(plan.eatTotal)}), style: const TextStyle(fontWeight: FontWeight.bold)),
              plan.eat.isEmpty ? const Text('—') : _chips(plan.eat),
              const SizedBox(height: 8),
              if (result == null)
                Text(context.t('cover.nothing'), style: TextStyle(color: err))
              else ...[
                Text(context.t('cover.coverNow', {'v': money(result.remainingTotal)}), style: const TextStyle(fontWeight: FontWeight.bold)),
                _chips(result.remainingLines),
              ],
            ],
            if (_error != null) Text(_error!, style: TextStyle(color: err)),
            const SizedBox(height: 8),
            FilledButton(onPressed: (eat == null || result == null) ? null : () => _save(eat), child: Text(context.t('cover.save'))),
          ]),
        ),
      ),
      if (covers.length > 1)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              KV(context.t('cover.count'), context.t('cover.countV', {'n': covers.length})),
              KV(context.t('cover.sumEat'), money(covers.fold(0.0, (a, v) => a + _sum(v.allocations))), bold: true),
              KV(context.t('cover.sumCover'), money(covers.fold(0.0, (a, v) => a + v.coverListTotal)), bold: true),
            ]),
          ),
        ),
      if (covers.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Center(child: Text(context.t('cover.empty')))),
      for (final v in covers)
        Card(
          child: ListTile(
            title: Text(v.code.isEmpty ? '—' : v.code),
            subtitle: Text(context.t('cover.sub', {'date': v.date, 'e': money(_sum(v.allocations)), 'c': money(v.coverListTotal)})),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _detail(context, v),
          ),
        ),
    ]);
  }

  /// What gets copied: this voucher's cover list, one "num=amount" per line plus the total (HTML format).
  String _receipt(LCover v) {
    final b = StringBuffer();
    for (final l in v.remainingLines) {
      b.writeln('${l.num}=${money(l.amount)}');
    }
    b.write('Total=${money(v.coverListTotal)}');
    return b.toString();
  }

  void _detail(BuildContext context, LCover v) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('cover.detail', {'code': v.code})),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ctx.t('cover.perNumber', {'v': money(v.requestedAmount), 'date': v.date})),
            const SizedBox(height: 12),
            Text(ctx.t('cover.eatenList', {'v': money(_sum(v.allocations))}), style: Theme.of(ctx).textTheme.titleSmall),
            Text(v.allocations.isEmpty ? '—' : v.allocations.map((l) => '${l.num}=${money(l.amount)}').join('   ')),
            const SizedBox(height: 12),
            Text(ctx.t('cover.coverList', {'v': money(v.coverListTotal)}), style: Theme.of(ctx).textTheme.titleSmall),
            Text(v.remainingLines.isEmpty ? '—' : v.remainingLines.map((l) => '${l.num}=${money(l.amount)}').join('   ')),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _receipt(v)));
              if (ctx.mounted) toast(ctx, ctx.t('cover.copied'));
            },
            child: Text(ctx.t('cover.copy')),
          ),
          TextButton(
            onPressed: () async {
              final ok = await confirmDialog(ctx, ctx.t('cover.deleteTitle'), ctx.t('cover.deleteBody', {'code': v.code}), ctx.t('common.delete'), danger: true);
              if (ok && context.mounted) {
                if (!await runOrToast(context, context.read<LedgerStore>(), Ops.coverDelete(v.id))) return;
                if (ctx.mounted) Navigator.pop(ctx);
              }
            },
            child: Text(ctx.t('common.delete')),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.t('common.close'))),
        ],
      ),
    );
  }
}
