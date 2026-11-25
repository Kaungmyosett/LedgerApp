import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/lang.dart';
import '../../ledger/ledger_store.dart';
import '../../ledger/logic.dart';
import 'common.dart';

class HomeTab extends StatelessWidget {
  const HomeTab({super.key, required this.openDebt});
  final VoidCallback openDebt;

  @override
  Widget build(BuildContext context) {
    final data = context.watch<LedgerStore>().data;
    final userIds = data.users.map((user) => user.id).toSet();
    final stake = data.entries
        .where((entry) => userIds.contains(entry.userId))
        .fold(0.0, (total, entry) => total + entry.total);
    final balances = numberBalances([], data.coverVouchers).values;
    final eaten = balances.fold(0.0, (total, balance) => total + balance.covered);
    final cover = balances.fold(0.0, (total, balance) => total + balance.cover);
    final debtBalances = data.debtBalances.values;
    final debt = debtBalances.where((value) => value > 0).fold(0, (sum, value) => sum + value);
    final payable = debtBalances.where((value) => value < 0).fold(0, (sum, value) => sum - value);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.t('settle.total')),
              Text(money(stake), style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 12),
              KV(context.t('home.userCount'), '${data.users.length}'),
              if (eaten > 0) KV(context.t('num.totalEaten'), money(eaten)),
              if (cover > 0) KV(context.t('num.totalCover'), money(cover)),
            ]),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.account_balance_wallet_outlined),
            title: Text(context.t('tab.debt')),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              KV(context.t('debt.outstanding'), money(debt / 100)),
              if (payable > 0) KV(context.t('debt.payable'), money(payable / 100)),
            ]),
            trailing: const Icon(Icons.chevron_right),
            onTap: openDebt,
          ),
        ),
      ],
    );
  }
}
