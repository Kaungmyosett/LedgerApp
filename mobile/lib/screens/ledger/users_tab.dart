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

class UsersTab extends StatefulWidget {
  const UsersTab({super.key});

  @override
  State<UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<UsersTab> {
  DrawPeriod? _selectedPeriod;

  DrawPeriod _period(BuildContext context) =>
      _selectedPeriod ?? context.read<DrawPeriod?>() ?? drawPeriodAt(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LedgerStore>();
    final data = store.data;
    final current = context.watch<DrawPeriod?>() ?? drawPeriodAt(DateTime.now());
    final period = _selectedPeriod ?? current;
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
                  child: _periodPicker(period),
                ),
                if (draw != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(context.t('settle.number', {'n': draw.number}), style: theme.textTheme.titleMedium),
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

  Widget _periodPicker(DrawPeriod period) => Wrap(
    spacing: 12,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      OutlinedButton.icon(
        icon: const Icon(Icons.event_outlined),
        label: Text(period.date),
        onPressed: () async {
          final date = await pickDate(context, period.date);
          if (date != null && mounted) {
            setState(() => _selectedPeriod = (date: date, session: period.session));
          }
        },
      ),
      SegmentedButton<String>(
        segments: [
          for (final session in ['morning', 'evening'])
            ButtonSegment(value: session, label: Text(sessionLabel(context, session))),
        ],
        selected: {period.session},
        onSelectionChanged: (sessions) =>
            setState(() => _selectedPeriod = (date: period.date, session: sessions.single)),
      ),
    ],
  );

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
              onPressed: () => _showUserReport(context, user, period: _period(context)),
            ),
            IconButton(
              tooltip: context.t('bets.add'),
              icon: const Icon(Icons.add),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ChangeNotifierProvider<LedgerStore>.value(
                  value: store,
                  child: EntryScreen.create(userId: user.id, period: _period(context)),
                ),
              )),
            ),
          ]),
        ),
        Material(
          color: theme.colorScheme.surfaceContainerHighest,
          child: InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => ChangeNotifierProvider<LedgerStore>.value(
                value: store, child: BetsTab.forUser(user: user, period: _period(context)),
              ),
            )),
            child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              KV(context.t('settle.total'), money(summary.total), bold: true),
              KV(context.t('money.commission'), money(summary.commission)),
              KV(context.t('users.numberCount'), '${numbers.length}'),
              if (summary.payment > 0) KV(context.t('money.payment'), money(summary.payment)),
              if (draw != null && summary.total > 0) ...[
                payoutRow(context, summary.payout, summary.winAmount, summary.odd),
                KV(context.t('users.net'), money(summary.net), bold: true),
              ],
            ]),
            ),
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
              _showUserReport(context, u, period: _period(context));
            },
          ),
          ListTile(
            leading: const Icon(Icons.format_list_numbered),
            title: Text(context.t('users.voucherNumbers')),
            onTap: () {
              Navigator.pop(ctx);
              _showUserReport(context, u, period: _period(context), voucherNumbers: true);
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
  var schedule = existing?.settlementSchedule ?? SettlementSchedule.daily;
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
            DropdownButtonFormField<SettlementSchedule>(
              initialValue: schedule,
              decoration: InputDecoration(labelText: ctx.t('users.schedule')),
              items: [
                for (final value in SettlementSchedule.values)
                  DropdownMenuItem(value: value, child: Text(ctx.t('users.schedule.${value.name}'))),
              ],
              onChanged: (value) {
                if (value != null) setS(() => schedule = value);
              },
            ),
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
              final u = LUser(id: existing?.id ?? newUuid(), name: n, username: n, commissionPercent: c, odd: o, payment: p, settlementSchedule: schedule);
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

/// Opens a read-only report for one commission user and draw period.
Future<void> _showUserReport(
  BuildContext context,
  LUser user, {
  required DrawPeriod period,
  bool voucherNumbers = false,
}) async {
  var date = period.date;
  var session = period.session;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final d = context.read<LedgerStore>().data;
      final period = (date: date, session: session);
      final draw = voucherNumbers ? null : d.drawFor(period);
      final amounts = <String, double>{};
      for (final entry in d.entriesFor(period).where((e) => e.userId == user.id)) {
        for (final line in entry.lines) {
          amounts.update(line.num, (amount) => amount + line.amount, ifAbsent: () => line.amount);
        }
      }
      final numbers = amounts.keys.toList()..sort();
      final lines = [for (final n in numbers) Line(n, amounts[n]!)];
      final s = settleUser(user, lines, draw?.number ?? '');
      return AlertDialog(
        title: Text(voucherNumbers
            ? ctx.t('users.voucherNumbers')
            : ctx.t('settle.title', {'name': user.name})),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final p = await pickDate(ctx, date);
                    if (p != null && ctx.mounted) setS(() => date = p);
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
            if (voucherNumbers) ...[
              if (lines.isEmpty)
                Text(ctx.t('bets.empty'))
              else ...[
                KV(ctx.t('bets.no'), ctx.t('users.amount'), bold: true),
                for (final line in lines) KV(line.num, money(line.amount)),
                const Divider(),
                KV(ctx.t('settle.total'), money(s.total), bold: true),
                KV(ctx.t('money.commission'), money(s.commission)),
              ],
            ] else if (lines.isEmpty)
              Text(ctx.t('settle.noStake'), style: const TextStyle(fontWeight: FontWeight.w600))
            else if (draw == null) ...[
              KV(context.t('settle.total'), money(s.total), bold: true),
              const SizedBox(height: 8),
              Text(context.t('settle.noDraw')),
            ] else ...[
              Text(context.t('settle.number', {'n': draw.number}), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              KV(context.t('settle.total'), money(s.total), bold: true),
              payoutRow(context, s.payout, s.winAmount, s.odd,
                  bold: s.payout > 0, color: s.payout > 0 ? Colors.red.shade700 : null),
              KV('${context.t('money.commission')} (${money(s.commissionPercent)}%)', money(s.commission)),
              KV(context.t('money.payment'), money(s.payment)),
              const Divider(),
              KV(context.t('money.net'), money(s.net), bold: true, color: s.net < 0 ? Colors.red : Colors.green.shade700),
            ],
          ]),
        ),
        actions: [
          if (voucherNumbers && lines.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                final receipt = [
                  '${ctx.t('bets.no')}\t${ctx.t('users.amount')}',
                  for (final line in lines) '${line.num}\t${money(line.amount)}',
                  '',
                  '${ctx.t('settle.total')} = ${money(s.total)}',
                  '${ctx.t('money.commission')} = ${money(s.commission)}',
                ].join('\n');
                await Clipboard.setData(ClipboardData(text: receipt));
                if (ctx.mounted) toast(ctx, ctx.t('users.voucherCopied'));
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
