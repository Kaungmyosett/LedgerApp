import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/lang.dart';
import '../../ledger/ledger_store.dart';
import '../../ledger/models.dart';
import '../../ledger/ops.dart';
import 'common.dart';

class DebtTab extends StatelessWidget {
  const DebtTab({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LedgerStore>();
    final data = store.data;
    final accounts = <String, List<LDebtEntry>>{};
    for (final entry in data.debtEntries) {
      accounts.putIfAbsent(entry.userId, () => []).add(entry);
    }
    final names = {for (final user in data.users) user.id: user.name};
    final total = data.debtEntries.fold(0, (sum, entry) => sum + entry.changeCents);
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: KV(context.t('debt.outstanding'), money(total / 100), bold: true),
            ),
          ),
          if (accounts.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(context.t('debt.empty'), textAlign: TextAlign.center),
            ),
          for (final account in accounts.entries)
            _DebtAccount(
              key: ValueKey(account.key),
              name: names[account.key] ?? account.value.last.userName,
              entries: account.value,
              repay: () => _record(context, store, userId: account.key),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'recordDebt',
        onPressed: names.isEmpty ? null : () => _record(context, store),
        icon: const Icon(Icons.add),
        label: Text(context.t('debt.add')),
      ),
    );
  }

  Future<void> _record(BuildContext context, LedgerStore store, {String? userId}) async {
    final users = store.data.users;
    final repayment = userId != null;
    final kind = repayment ? 'repayment' : 'debt';
    var amount = '';
    var selectedUser = userId ?? users.first.id;
    var date = today();
    var saving = false;
    String? error;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => StatefulBuilder(builder: (dialog, update) {
        return AlertDialog(
          title: Text(dialog.t(repayment ? 'debt.repay' : 'debt.add')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (!repayment)
                DropdownButtonFormField<String>(
                  initialValue: selectedUser,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: dialog.t('bets.user')),
                  items: [
                    for (final user in users)
                      DropdownMenuItem(value: user.id, child: Text(user.name)),
                  ],
                  onChanged: saving ? null : (id) => update(() => selectedUser = id!),
                ),
              OutlinedButton.icon(
                onPressed: saving ? null : () async {
                  final chosen = await pickDate(dialog, date);
                  if (chosen != null && dialog.mounted) update(() => date = chosen);
                },
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text(date),
              ),
              TextField(
                onChanged: (value) => amount = value,
                enabled: !saving,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: dialog.t('users.amount'), errorText: error, errorMaxLines: 3),
              ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialog),
              child: Text(dialog.t('common.cancel')),
            ),
            FilledButton(
              onPressed: saving ? null : () async {
                final value = parseAmount(amount);
                if (value == null || value > 1e12) {
                  update(() => error = dialog.t('debt.invalid'));
                  return;
                }
                update(() { saving = true; error = null; });
                try {
                  await store.run(Ops.debtRecord(selectedUser, date, kind, value));
                  if (dialog.mounted) Navigator.pop(dialog);
                } on LedgerRule catch (e) {
                  if (dialog.mounted) {
                    update(() {
                      error = trRule(dialog, e.code, e.message);
                      saving = false;
                    });
                  }
                }
              },
              child: Text(dialog.t('common.save')),
            ),
          ],
        );
      }),
    );
  }
}

class _DebtAccount extends StatelessWidget {
  const _DebtAccount({super.key, required this.name, required this.entries, required this.repay});

  final String name;
  final List<LDebtEntry> entries;
  final VoidCallback repay;

  @override
  Widget build(BuildContext context) {
    final balance = entries.fold(0, (sum, entry) => sum + entry.changeCents);
    final ordered = [...entries]..sort((a, b) {
      final date = b.date.compareTo(a.date);
      return date == 0 ? b.createdAt.compareTo(a.createdAt) : date;
    });
    return Card(
      child: ExpansionTile(
        title: Text(name),
        subtitle: Text('${context.t('debt.outstanding')}  ${money(balance / 100)}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          for (final entry in ordered)
            KV('${entry.date} · ${context.t('debt.${entry.kind}')}', money(entry.amount)),
          if (balance > 0)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: repay,
                icon: const Icon(Icons.payments_outlined),
                label: Text(context.t('debt.repay')),
              ),
            ),
        ],
      ),
    );
  }
}
