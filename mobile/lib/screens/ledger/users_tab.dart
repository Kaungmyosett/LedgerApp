import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../i18n/lang.dart';
import '../../ledger/draw_period.dart';
import '../../ledger/ledger_store.dart';
import '../../ledger/logic.dart';
import '../../ledger/models.dart';
import '../../ledger/ops.dart';
import 'bets_tab.dart';
import 'common.dart';

class UsersTab extends StatelessWidget {
  const UsersTab({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LedgerStore>();
    final data = store.data;
    final period = context.watch<DrawPeriod?>() ?? drawPeriodAt(DateTime.now());
    final draw = data.drawFor(period);
    final entriesByUser = <String, List<Line>>{};
    for (final entry in data.entriesFor(period)) {
      entriesByUser.putIfAbsent(entry.userId, () => []).addAll(entry.lines);
    }
    final theme = Theme.of(context);
    return Scaffold(
      body: data.users.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(context.t('users.empty'), textAlign: TextAlign.center)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text('${period.date} · ${sessionLabel(context, period.session)}', style: theme.textTheme.titleSmall),
                ),
                for (final user in data.users)
                  _userCard(context, store, user, entriesByUser[user.id] ?? const [], draw),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'addUser',
        onPressed: () => showUserForm(context),
        icon: const Icon(Icons.person_add),
        label: Text(context.t('users.add')),
      ),
    );
  }

  Widget _userCard(BuildContext context, LedgerStore store, LUser user, List<Line> lines, LDraw? draw) {
    final theme = Theme.of(context);
    final summary = settleUser(user, lines, draw?.number ?? '');
    final numbers = lines.where((line) => line.amount > 0).map((line) => line.num).toSet();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person_outline)),
          title: Text(user.name, style: theme.textTheme.titleMedium),
          subtitle: Text(context.t('users.sub', {'c': money(user.commissionPercent), 'o': money(user.odd)})),
          onTap: () => _actions(context, user),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: context.t('users.settlement'),
              icon: const Icon(Icons.receipt_long_outlined),
              onPressed: () => showSettlement(context, user),
            ),
            IconButton(
              tooltip: context.t('bets.add'),
              icon: const Icon(Icons.add),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ChangeNotifierProvider<LedgerStore>.value(
                  value: store,
                  child: EntryScreen(userId: user.id),
                ),
              )),
            ),
          ]),
        ),
        ColoredBox(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              KV(context.t('settle.total'), money(summary.total), bold: true),
              KV(context.t('money.commission'), money(summary.commission)),
              KV(context.t('bets.no'), '${numbers.length}'),
              if (draw != null && summary.total > 0) ...[
                KV(context.t('money.payout'), money(summary.payout)),
                KV(context.t('users.net'), money(summary.net), bold: true),
              ],
            ]),
          ),
        ),
      ]),
    );
  }

  void _actions(BuildContext context, LUser u) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(u.name, style: Theme.of(ctx).textTheme.titleMedium)),
          ListTile(
            leading: const Icon(Icons.calculate),
            title: Text(context.t('users.settlement')),
            onTap: () {
              Navigator.pop(ctx);
              showSettlement(context, u);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit),
            title: Text(context.t('common.edit')),
            onTap: () {
              Navigator.pop(ctx);
              showUserForm(context, existing: u);
            },
          ),
          ListTile(
            leading: Icon(Icons.delete, color: Theme.of(ctx).colorScheme.error),
            title: Text(context.t('common.delete')),
            onTap: () async {
              Navigator.pop(ctx);
              final ok = await confirmDialog(context, context.t('users.deleteTitle'), context.t('users.deleteBody', {'name': u.name}), context.t('common.delete'), danger: true);
              if (ok && context.mounted) {
                try {
                  await context.read<LedgerStore>().run(Ops.userDelete(u.id));
                } on LedgerRule catch (e) {
                  if (context.mounted) toast(context, trRule(context, e.code, e.message));
                }
              }
            },
          ),
        ]),
      ),
    );
  }
}

Future<void> showUserForm(BuildContext context, {LUser? existing}) async {
  String plain(double v) => money(v).replaceAll(',', '');
  final name = TextEditingController(text: existing?.name ?? '');
  final comm = TextEditingController(text: existing != null ? plain(existing.commissionPercent) : '10');
  final odd = TextEditingController(text: existing != null ? plain(existing.odd) : '80');
  final pay = TextEditingController(text: existing?.payment != null ? plain(existing!.payment!) : '');
  String? error;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      return AlertDialog(
        title: Text(context.t(existing == null ? 'users.addTitle' : 'users.editTitle')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, maxLength: 50, decoration: InputDecoration(labelText: context.t('users.name'), counterText: '')),
            TextField(controller: comm, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: context.t('users.commission'))),
            TextField(controller: odd, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: context.t('users.odd'))),
            TextField(controller: pay, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: context.t('users.payment'))),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.t('common.cancel'))),
          FilledButton(
            onPressed: () async {
              final n = name.text.trim();
              final c = double.tryParse(comm.text.trim());
              final o = double.tryParse(odd.text.trim());
              final p = pay.text.trim().isEmpty ? null : double.tryParse(pay.text.trim());
              if (n.isEmpty) return setS(() => error = context.t('users.errName'));
              if (c == null || c < 0 || c > 100) return setS(() => error = context.t('users.errCommission'));
              if (o == null || o < 0) return setS(() => error = context.t('users.errOdd'));
              if (pay.text.trim().isNotEmpty && (p == null || p < 0)) return setS(() => error = context.t('users.errPayment'));
              final store = context.read<LedgerStore>();
              // Users are identified by name only; the server's username field gets the same value.
              final u = LUser(id: existing?.id ?? newUuid(), name: n, username: n, commissionPercent: c, odd: o, payment: p);
              try {
                await store.run(existing == null ? Ops.userCreate(u) : Ops.userUpdate(u));
                if (ctx.mounted) Navigator.pop(ctx);
              } on LedgerRule catch (e) {
                setS(() => error = trRule(context, e.code, e.message));
              }
            },
            child: Text(context.t('common.save')),
          ),
        ],
      );
    }),
  );
}

/// One user's result for a chosen date and session (read-only; nothing is saved).
Future<void> showSettlement(BuildContext context, LUser u) async {
  final current = context.read<DrawPeriod?>() ?? drawPeriodAt(DateTime.now());
  var date = current.date;
  var session = current.session;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final d = context.read<LedgerStore>().data;
      final period = (date: date, session: session);
      final draw = d.drawFor(period);
      final amounts = <String, double>{};
      for (final entry in d.entriesFor(period).where((e) => e.userId == u.id)) {
        for (final line in entry.lines) {
          amounts.update(line.num, (amount) => amount + line.amount, ifAbsent: () => line.amount);
        }
      }
      final numbers = amounts.keys.toList()..sort();
      final lines = [for (final n in numbers) Line(n, amounts[n]!)];
      final s = settleUser(u, lines, draw?.number ?? '');
      final receipt = [
        '${ctx.t('bets.no')}	${ctx.t('users.amount')}',
        for (final line in lines) '${line.num}	${money(line.amount)}',
        '',
        '${ctx.t('settle.total')} = ${money(s.total)}',
        '${ctx.t('money.commission')} = ${money(s.commission)}',
      ].join('\n');
      return AlertDialog(
        title: Text(context.t('settle.title', {'name': u.name})),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final p = await pickDate(ctx, date);
                    if (p != null) setS(() => date = p);
                  },
                  child: Text(date),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: session,
                items: [
                  DropdownMenuItem(value: 'morning', child: Text(context.t('common.morning'))),
                  DropdownMenuItem(value: 'evening', child: Text(context.t('common.evening'))),
                ],
                onChanged: (v) => setS(() => session = v ?? session),
              ),
            ]),
            const SizedBox(height: 12),
            if (lines.isEmpty)
              Text(context.t('settle.noStake'), style: const TextStyle(fontWeight: FontWeight.w600))
            else if (draw == null) ...[
              KV(context.t('settle.total'), money(s.total), bold: true),
              const SizedBox(height: 8),
              Text(context.t('settle.noDraw')),
            ] else ...[
              Text(context.t('settle.number', {'n': draw.number}), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              KV(context.t('settle.total'), money(s.total), bold: true),
              KV('${context.t('money.payout')} (${money(s.winAmount)} × ${money(s.odd)})', money(s.payout),
                  bold: s.payout > 0, color: s.payout > 0 ? Colors.red.shade700 : null),
              KV('${context.t('money.commission')} (${money(s.commissionPercent)}%)', money(s.commission)),
              KV(context.t('money.payment'), money(s.payment)),
              const Divider(),
              KV(context.t('money.net'), money(s.net), bold: true, color: s.net < 0 ? Colors.red : Colors.green.shade700),
            ],
            const Divider(height: 24),
            Text(ctx.t('users.voucherNumbers'), style: Theme.of(ctx).textTheme.titleSmall),
            if (lines.isNotEmpty) ...[
              KV(ctx.t('bets.no'), ctx.t('users.amount'), bold: true),
              for (final line in lines) KV(line.num, money(line.amount)),
              const Divider(),
              KV(ctx.t('settle.total'), money(s.total), bold: true),
              KV(ctx.t('money.commission'), money(s.commission)),
            ] else
              Text(ctx.t('bets.empty')),
          ]),
        ),
        actions: [
          if (lines.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: receipt));
                if (ctx.mounted) toast(context, ctx.t('users.voucherCopied'));
              },
              icon: const Icon(Icons.copy),
              label: Text(ctx.t('common.copy')),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.t('common.close'))),
        ],
      );
    }),
  );
}
