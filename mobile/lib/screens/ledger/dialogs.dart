import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/lang.dart';
import '../../ledger/draw_period.dart';
import '../../ledger/ledger_store.dart';
import '../../ledger/logic.dart';
import '../../ledger/ops.dart';
import '../../util/format.dart';
import 'common.dart';

Future<void> showBlockedNumbers(BuildContext context) async {
  final store = context.read<LedgerStore>();
  final c = TextEditingController(text: store.data.blockedNumbers.join(', '));
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.t('blocked.title')),
      content: TextField(
        controller: c,
        minLines: 2,
        maxLines: 5,
        decoration: InputDecoration(hintText: '07, 13, 77', helperText: ctx.t('blocked.help'), helperMaxLines: 2),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.t('common.cancel'))),
        FilledButton(
          onPressed: () async {
            if (!await runOrToast(ctx, store, Ops.blockedSet(parseBlockedNumbers(c.text)))) return;
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: Text(ctx.t('common.save')),
        ),
      ],
    ),
  );
}

/// Enter / overwrite / delete the winning number for a date and session.
Future<void> showDrawResults(BuildContext context) async {
  final store = context.read<LedgerStore>();
  var date = today();
  var session = drawSession(DateTime.now());
  final number = TextEditingController();
  String? error;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final draws = sortDraws(store.data.drawResults);
      return AlertDialog(
        title: Text(ctx.t('draw.title')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () async { final p = await pickDate(ctx, date); if (p != null) setS(() => date = p); }, child: Text(date))),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: session,
                items: [DropdownMenuItem(value: 'morning', child: Text(ctx.t('common.morning'))), DropdownMenuItem(value: 'evening', child: Text(ctx.t('common.evening')))],
                onChanged: (v) => setS(() => session = v ?? session),
              ),
            ]),
            TextField(controller: number, keyboardType: TextInputType.number, maxLength: 2, decoration: InputDecoration(labelText: ctx.t('draw.number'), counterText: '')),
            if (error != null) Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            FilledButton(
              onPressed: () async {
                final t = number.text.trim();
                if (!RegExp(r'^\d{1,2}$').hasMatch(t)) return setS(() => error = ctx.t('draw.err'));
                if (!await runOrToast(ctx, store, Ops.drawSave(date, session, t.padLeft(2, '0')))) return;
                number.clear();
                setS(() => error = null);
              },
              child: Text(ctx.t('common.save')),
            ),
            const Divider(),
            if (draws.isEmpty) Text(ctx.t('common.none')),
            for (final x in draws)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${x.date} · ${sessionLabel(ctx, x.session)}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(x.number, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await confirmDialog(ctx, ctx.t('draw.deleteTitle'), ctx.t('draw.deleteBody', {'date': x.date, 'session': sessionLabel(ctx, x.session), 'n': x.number}), ctx.t('common.delete'), danger: true);
                      if (ok) {
                        await runOrToast(ctx, store, Ops.drawDelete(x.date, x.session));
                        setS(() {});
                      }
                    },
                  ),
                ]),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.t('common.close')))],
      );
    }),
  );
}

/// Finalize one draw: freezes vouchers for its date and session.
Future<void> showFinalize(BuildContext context) async {
  final store = context.read<LedgerStore>();
  final d = store.data;
  final open = sortDraws(d.drawResults).where((x) => !d.finalizedRecords.any((r) => r.date == x.date && r.session == x.session)).toList();
  if (open.isEmpty) return toast(context, context.t('fin.none'));
  var pick = open.first;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final entries = d.entriesFor((date: pick.date, session: pick.session));
      final dayEntries = entries.length;
      final withStake = d.users.where((u) => entries.any((e) => e.userId == u.id && e.total > 0)).length;
      return AlertDialog(
        title: Text(ctx.t('fin.title')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButton<int>(
            isExpanded: true,
            value: open.indexOf(pick),
            items: [for (var i = 0; i < open.length; i++) DropdownMenuItem(value: i, child: Text('${open[i].date} · ${sessionLabel(ctx, open[i].session)} · ${open[i].number}'))],
            onChanged: (i) => setS(() => pick = open[i ?? 0]),
          ),
          const SizedBox(height: 8),
          Text(ctx.t('fin.body', {'n': pick.number, 'u': withStake, 'date': '${pick.date} · ${sessionLabel(ctx, pick.session)}', 'v': dayEntries})),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.t('common.cancel'))),
          FilledButton(
            onPressed: () async {
              final ids = {for (final u in d.users) u.id: newUuid()};
              try {
                await store.run(Ops.finalize(pick.date, pick.session, ids));
                if (ctx.mounted) Navigator.pop(ctx);
              } on LedgerRule catch (e) {
                if (ctx.mounted) toast(ctx, trRule(ctx, e.code, e.message));
              }
            },
            child: Text(ctx.t('fin.btn')),
          ),
        ],
      );
    }),
  );
}

Future<void> showBlockedLog(BuildContext context) {
  final store = context.read<LedgerStore>();
  return Navigator.of(context).push<void>(MaterialPageRoute(
    builder: (route) => Scaffold(
      appBar: AppBar(title: Text(route.t('menu.blockedLog'))),
      body: ListenableBuilder(
        listenable: store,
        builder: (ctx, _) {
          final rows = [...store.data.blockedLog]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
          if (rows.isEmpty) return Center(child: Text(ctx.t('blocked.logEmpty')));
          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (rowContext, index) {
              final row = rows[index];
              final created = DateTime.tryParse(row.createdAt)?.toLocal();
              return ListTile(
                key: ValueKey((row.opId, row.num)),
                title: Text(row.userName),
                subtitle: Text([
                  '${rowContext.t('bets.no')} ${row.num} · ${money(row.amount)}',
                  if (created != null) formatDateTime(created),
                ].join('\n')),
                isThreeLine: created != null,
                trailing: IconButton(
                  tooltip: rowContext.t('common.delete'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final ok = await confirmDialog(
                      rowContext,
                      rowContext.t('blocked.deleteLogTitle'),
                      rowContext.t('blocked.deleteLogBody', {'name': row.userName, 'n': row.num}),
                      rowContext.t('common.delete'),
                      danger: true,
                    );
                    if (ok && rowContext.mounted) {
                      await runOrToast(rowContext, store, Ops.blockedLogDelete(row.opId, row.num));
                    }
                  },
                ),
              );
            },
          );
        },
      ),
    ),
  ));
}
