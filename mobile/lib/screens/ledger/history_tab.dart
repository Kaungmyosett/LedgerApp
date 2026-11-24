import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/lang.dart';
import '../../ledger/ledger_store.dart';
import '../../ledger/models.dart';
import '../../ledger/ops.dart';
import 'common.dart';

/// Finalized settlements grouped by draw (date + session), newest first.
/// Each user shows: total stake, payout, commission earned, payment, final total. Each record can be deleted.
class HistoryTab extends StatelessWidget {
  const HistoryTab({super.key});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<LedgerStore>().data;
    if (d.finalizedRecords.isEmpty) return Center(child: Text(context.t('hist.empty')));

    final groups = <String, List<LFinal>>{};
    for (final r in d.finalizedRecords) {
      groups.putIfAbsent('${r.date}|${r.session}', () => []).add(r);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        final pa = a.split('|'), pb = b.split('|');
        final c = pb[0].compareTo(pa[0]);
        if (c != 0) return c;
        return (pb[1] == 'evening' ? 1 : 0) - (pa[1] == 'evening' ? 1 : 0);
      });

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: keys.length,
      // All draws start closed; tap one to open it.
      itemBuilder: (ctx, i) => _DrawGroup(records: groups[keys[i]]!, initiallyExpanded: false),
    );
  }
}

class _DrawGroup extends StatelessWidget {
  const _DrawGroup({required this.records, required this.initiallyExpanded});
  final List<LFinal> records;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final first = records.first;
    double sum(double Function(LFinal) f) => records.fold(0.0, (a, r) => a + f(r));
    final totalNet = sum((r) => r.net);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: cs.primary,
          child: Text(first.number, style: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.bold, fontSize: 18)),
        ),
        title: Text('${first.date} · ${sessionLabel(context, first.session)}', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${context.t('hist.number', {'n': first.number})} · ${context.t('hist.users', {'n': records.length})}'),
        trailing: _Amount(totalNet, bold: true),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          for (final r in records) _RecordCard(r: r),
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(10)),
            child: Column(children: [
              Align(alignment: Alignment.centerLeft, child: Text(context.t('hist.groupTotal'), style: TextStyle(fontWeight: FontWeight.bold, color: cs.onPrimaryContainer))),
              const SizedBox(height: 6),
              _row(context, 'money.total', sum((r) => r.total)),
              _row(context, 'money.payout', sum((r) => r.payout)),
              _row(context, 'money.commission', sum((r) => r.commission)),
              _row(context, 'money.payment', sum((r) => r.payment)),
              const Divider(),
              _row(context, 'money.net', totalNet, net: true),
            ]),
          ),
        ],
      ),
    );
  }
}

Widget _row(BuildContext context, String key, double v, {String? note, bool net = false}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      Expanded(
        child: Text.rich(TextSpan(children: [
          TextSpan(text: context.t(key), style: TextStyle(fontWeight: net ? FontWeight.bold : null)),
          if (note != null) TextSpan(text: '  $note', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
        ])),
      ),
      net ? _Amount(v, bold: true) : Text(money(v), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
    ]),
  );
}

class _Amount extends StatelessWidget {
  const _Amount(this.v, {this.bold = false});
  final double v;
  final bool bold;
  @override
  Widget build(BuildContext context) => Text(
        money(v),
        style: TextStyle(
          fontWeight: bold ? FontWeight.bold : null,
          fontSize: bold ? 16 : null,
          color: v < 0 ? Colors.red.shade700 : Colors.green.shade700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.r});
  final LFinal r;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 10),
      decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant), borderRadius: BorderRadius.circular(10)),
      child: Column(children: [
        Row(children: [
          Expanded(child: Text(r.userName, style: Theme.of(context).textTheme.titleSmall)),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: context.t('common.delete'),
            icon: Icon(Icons.delete_outline, color: cs.error),
            onPressed: () => _delete(context),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Column(children: [
            _row(context, 'money.total', r.total),
            _row(context, 'money.payout', r.payout, note: context.t('hist.winDetail', {'w': money(r.winAmount), 'o': money(r.odd)})),
            _row(context, 'money.commission', r.commission),
            _row(context, 'money.payment', r.payment),
            const Divider(height: 12),
            _row(context, 'money.net', r.net, net: true),
          ]),
        ),
      ]),
    );
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await confirmDialog(context, context.t('hist.deleteTitle'), context.t('hist.deleteBody', {'name': r.userName}), context.t('common.delete'), danger: true);
    if (ok && context.mounted) await runOrToast(context, context.read<LedgerStore>(), Ops.finalizedDelete(r.id));
  }
}
