import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/lang.dart';
import '../../ledger/ledger_store.dart';
import '../../ledger/logic.dart';
import '../../ledger/models.dart';
import '../../ledger/ops.dart';
import 'common.dart';

class UsersTab extends StatelessWidget {
  const UsersTab({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LedgerStore>();
    final users = store.data.users;
    // Latest draw result: a user who staked that number on that date has a payout to show.
    final sorted = sortDraws(store.data.drawResults);
    final draw = sorted.isEmpty ? null : sorted.first;
    return Scaffold(
      body: users.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(context.t('users.empty'), textAlign: TextAlign.center)))
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: users.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final u = users[i];
                final total = store.data.entries.where((e) => e.userId == u.id).fold(0.0, (a, e) => a + e.total);
                // Stake on the latest winning number (plain amount, not multiplied by the odd).
                final winAmount = draw == null
                    ? 0.0
                    : settleUser(u, store.data.entries.where((e) => e.userId == u.id && e.date == draw.date).expand((e) => e.lines).toList(), draw.number).winAmount;
                return ListTile(
                  title: Text(u.name),
                  // Winning stake (if the latest draw hits) is shown as a red amount right after the payment.
                  subtitle: Text.rich(TextSpan(children: [
                    TextSpan(text: context.t('users.sub', {'c': money(u.commissionPercent), 'o': money(u.odd)}) +
                        (u.payment != null ? context.t('users.subPay', {'p': money(u.payment!)}) : '')),
                    if (winAmount > 0)
                      TextSpan(text: ' · ${context.t('money.payout')} ${money(winAmount)}', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red.shade700)),
                  ])),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(money(total), style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(context.t('settle.total'), style: const TextStyle(fontSize: 11)),
                  ]),
                  onTap: () => _actions(ctx, u),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showUserForm(context),
        icon: const Icon(Icons.person_add),
        label: Text(context.t('users.add')),
      ),
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
  var date = today();
  var session = 'evening';
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final d = context.read<LedgerStore>().data;
      final draw = d.drawResults.where((x) => x.date == date && x.session == session).firstOrNull;
      final lines = d.entries.where((e) => e.userId == u.id && e.date == date).expand((e) => e.lines).toList();
      final s = draw == null ? null : settleUser(u, lines, draw.number);
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
            if (lines.fold(0.0, (a, x) => a + x.amount) == 0)
              Text(context.t('settle.noStake'), style: const TextStyle(fontWeight: FontWeight.w600))
            else if (draw == null) ...[
              KV(context.t('settle.total'), money(lines.fold(0.0, (a, x) => a + x.amount)), bold: true),
              const SizedBox(height: 8),
              Text(context.t('settle.noDraw')),
            ] else ...[
              Text(context.t('settle.number', {'n': draw.number}), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              KV(context.t('settle.total'), money(s!.total), bold: true),
              KV('${context.t('money.payout')} (${money(s.winAmount)} × ${money(s.odd)})', money(s.payout),
                  bold: s.payout > 0, color: s.payout > 0 ? Colors.red.shade700 : null),
              KV('${context.t('money.commission')} (${money(s.commissionPercent)}%)', money(s.commission)),
              KV(context.t('money.payment'), money(s.payment)),
              const Divider(),
              KV(context.t('money.net'), money(s.net), bold: true, color: s.net < 0 ? Colors.red : Colors.green.shade700),
            ],
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.t('common.close')))],
      );
    }),
  );
}
