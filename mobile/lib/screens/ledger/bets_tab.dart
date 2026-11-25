import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/lang.dart';
import '../../ledger/draw_period.dart';
import '../../ledger/ledger_store.dart';
import '../../ledger/logic.dart';
import '../../ledger/models.dart';
import '../../ledger/ops.dart';
import 'common.dart';

class BetsTab extends StatefulWidget {
  const BetsTab({super.key}) : user = null, period = null;
  const BetsTab.forUser({super.key, required LUser user, required DrawPeriod period})
      : user = user, period = period;

  final LUser? user;
  final DrawPeriod? period;
  @override
  State<BetsTab> createState() => _BetsTabState();
}

class _BetsTabState extends State<BetsTab> {
  String? _userFilter;
  bool _selecting = false;
  final _selected = <String>{};

  void _toggle(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  Future<void> _delete(List<LEntry> entries) async {
    final single = entries.length == 1;
    final deleted = await deleteVouchers(
      context, context.read<LedgerStore>(),
      [for (final entry in entries) Ops.entryDelete(entry.id)],
      title: context.t(single ? 'bets.deleteTitle' : 'vouchers.deleteTitle'),
      body: context.t(single ? 'bets.deleteBody' : 'vouchers.deleteBody', {'n': entries.length}),
    );
    if (deleted && mounted) setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LedgerStore>();
    final d = store.data;
    final names = {for (final u in d.users) u.id: u.name};
    final user = widget.user;
    final period = widget.period;
    final filter = user?.id ?? _userFilter;
    final list = (period == null ? d.entries : d.entriesFor(period))
        .where((e) => filter == null || e.userId == filter).toList().reversed.toList();
    final selected = list.where((entry) => _selected.contains(entry.id)).toList();
    return Scaffold(
      appBar: user == null ? null : AppBar(title: Text('${user.name} · ${context.t('tab.bets')}')),
      body: Column(children: [
        if (user == null && d.users.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: DropdownButtonFormField<String?>(
              initialValue: _userFilter,
              decoration: InputDecoration(labelText: context.t('bets.user'), isDense: true),
              items: [
                DropdownMenuItem<String?>(value: null, child: Text(context.t('bets.allUsers'))),
                ...d.users.map((u) => DropdownMenuItem<String?>(value: u.id, child: Text(u.name))),
              ],
              onChanged: (v) => setState(() => _userFilter = v),
            ),
          ),
        if (period != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('${period.date} · ${sessionLabel(context, period.session)}'),
          ),
        if (user != null && (list.length > 1 || _selecting))
          VoucherSelectionBar(
            selecting: _selecting, count: selected.length,
            toggle: () => setState(() { _selecting = !_selecting; _selected.clear(); }),
            delete: () => _delete(selected),
          ),
        Expanded(
          child: list.isEmpty
              ? Center(child: Text(context.t('bets.empty')))
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final e = list[i];
                    return ListTile(
                      title: Text('${e.code.isEmpty ? '—' : e.code} · ${names[e.userId] ?? context.t('common.unknown')}'),
                      subtitle: Text(context.t('bets.sub', {'date': e.date, 'n': e.lines.length, 'mode': context.t(e.mode == 'format' ? 'bets.format' : 'bets.manual')})),
                      leading: _selecting ? Checkbox(
                        value: _selected.contains(e.id), onChanged: (_) => _toggle(e.id),
                      ) : null,
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(money(e.total), style: const TextStyle(fontWeight: FontWeight.bold)),
                        if (!_selecting) IconButton(
                          tooltip: context.t('common.delete'), icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete([e]),
                        ),
                      ]),
                      onTap: _selecting ? () => _toggle(e.id) : () => Navigator.of(ctx).push(MaterialPageRoute<void>(
                        builder: (_) => ChangeNotifierProvider<LedgerStore>.value(value: store, child: EntryScreen.edit(existing: e)),
                      )),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

/// Row kinds for manual entry. 'num' = one number; the others expand like the Format text does.
const _kinds = ['num', 'R', 'PP', 'TO', 'BO', 'BK', 'KHWE', 'KHWEPU', 'Power', 'Natkat', 'Nyiko'];
bool _digitKind(String k) => k == 'PP' || k == 'TO' || k == 'BO' || k == 'BK';
bool _noNumber(String k) => k == 'Power' || k == 'Natkat' || k == 'Nyiko';
/// ခွေ / ခွေပူး: the number box takes 2–10 digits, e.g. 012.
bool _khweKind(String k) => k == 'KHWE' || k == 'KHWEPU';

class _Row {
  String kind = 'num';
  final num = TextEditingController();
  final amount = TextEditingController();
}

/// Expands one manual row into lines. Returns null (and sets [err]) when the row is invalid; empty rows give [].
List<Line>? _rowLines(_Row r, void Function(String) err, String Function(String, Map<String, Object?>) t) {
  final n = r.num.text.trim();
  final a = r.amount.text.trim().replaceAll(',', '');
  if ((n.isEmpty || _noNumber(r.kind)) && a.isEmpty) return const [];
  if (r.kind == 'num') {
    final v = parseAmount(a);
    if (!RegExp(r'^\d{1,2}$').hasMatch(n) || v == null) {
      err(t('bets.errRow', {'n': n, 'a': a}));
      return null;
    }
    return [Line(n.padLeft(2, '0'), v)];
  }
  // The other kinds use the same rules as the Format box (whole-number amounts).
  final okNum = _noNumber(r.kind) ||
      (_digitKind(r.kind)
          ? RegExp(r'^\d$').hasMatch(n)
          : _khweKind(r.kind)
              ? RegExp(r'^\d{2,20}$').hasMatch(n) && n.split('').toSet().length >= 2
              : RegExp(r'^\d{1,2}$').hasMatch(n));
  if (!okNum || !RegExp(r'^\d{1,12}$').hasMatch(a) || int.parse(a) <= 0) {
    err(t('bets.errRowKind', {'k': t('kind.${r.kind}', const {}), 'n': n, 'a': a}));
    return null;
  }
  final text = switch (r.kind) {
    'R' => '${n}R$a',
    'Power' || 'Natkat' || 'Nyiko' => '${r.kind} $a',
    _ => '$n${r.kind}$a',
  };
  final p = parseFormat(text);
  if (p.errors.isNotEmpty || p.result.isEmpty) {
    err(t('bets.errRowKind', {'k': t('kind.${r.kind}', const {}), 'n': n, 'a': a}));
    return null;
  }
  return p.result;
}

/// Adds amounts of the same number together, keeping first-seen order.
List<Line> _merge(List<Line> l) {
  final m = <String, double>{};
  for (final x in l) {
    m[x.num] = (m[x.num] ?? 0) + x.amount;
  }
  return [for (final e in m.entries) Line(e.key, e.value)];
}

/// New voucher (Format text or manual rows) or edit/delete an existing one (rows).
class EntryScreen extends StatefulWidget {
  const EntryScreen.create({super.key, required String userId, this.period})
      : userId = userId, existing = null;
  const EntryScreen.edit({super.key, required LEntry existing})
      : existing = existing, userId = null, period = null;
  final LEntry? existing;
  final DrawPeriod? period;
  final String? userId;
  @override
  State<EntryScreen> createState() => _EntryScreenState();
}

class _EntryScreenState extends State<EntryScreen> {
  String get _userId => widget.existing?.userId ?? widget.userId!;
  late String _date, _session;
  late bool _formatMode;
  final _format = TextEditingController();
  final List<_Row> _rows = [];
  String? _error;
  bool _busy = false;
  bool _editedInputs = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final initial = widget.period ?? drawPeriodAt(DateTime.now());
    _date = e?.date ?? initial.date;
    final legacyTime = DateTime.tryParse(e?.createdAt ?? '');
    _session = e?.session ?? (legacyTime == null ? initial.session : legacyDrawSession(legacyTime));
    _formatMode = e == null;
    if (e != null) {
      for (final l in e.lines) {
        _rows.add(_Row()..num.text = l.num..amount.text = money(l.amount).replaceAll(',', ''));
      }
    } else {
      _rows.add(_Row());
    }
  }

  @override
  void dispose() {
    _format.dispose();
    for (final row in _rows) {
      row.num.dispose();
      row.amount.dispose();
    }
    for (final row in _removedRows) {
      row.num.dispose();
      row.amount.dispose();
    }
    super.dispose();
  }

  final _removedRows = <_Row>[];

  void _inputChanged(String _) => setState(() => _editedInputs = true);

  /// Lines described by the current inputs; sets [_error] text when something is wrong.
  List<Line>? _collect({bool silent = false}) {
    String? err;
    List<Line>? out;
    if (_formatMode && !_editing) {
      final p = parseFormat(_format.text);
      if (p.errors.isNotEmpty) {
        err = p.errors.map((x) => trParseError(context, x)).join('\n');
      } else if (p.result.isEmpty) {
        err = context.t('bets.errFormat');
      } else {
        out = p.result;
      }
    } else {
      final lines = <Line>[];
      for (final r in _rows) {
        final got = _rowLines(r, (m) => err = m, context.t);
        if (got == null) break;
        lines.addAll(got);
      }
      if (err == null && lines.isEmpty) err = context.t('bets.errEmpty');
      if (err == null) out = _merge(lines);
    }
    if (!silent) _error = err;
    return err == null ? out : null;
  }

  Future<void> _save() async {
    setState(() => _error = null);
    final lines = _collect();
    if (lines == null) return setState(() {});
    final store = context.read<LedgerStore>();
    final removed = lines.where((line) => store.data.blockedNumbers.contains(line.num)).toList();
    setState(() => _busy = true);
    try {
      if (_editing) {
        await store.run(Ops.entryUpdate(widget.existing!.id, lines));
      } else {
        await store.run(Ops.entryCreate(LEntry(
          id: newUuid(), userId: _userId, code: newVoucherCode('V'), mode: _formatMode ? 'format' : 'manual', date: _date, session: _session,
          createdAt: DateTime.now().toUtc().toIso8601String(), lines: lines)));
      }
      if (!mounted) return;
      if (removed.isNotEmpty) {
        final label = removed.length == lines.length ? 'bets.allBlocked' : 'bets.blockedRemoved';
        toast(context, context.t(label, {'v': money(removed.fold(0.0, (sum, line) => sum + line.amount))}));
      }
      Navigator.pop(context);
    } on LedgerRule catch (e) {
      if (mounted) setState(() { _error = trRule(context, e.code, e.message); _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<LedgerStore>().data;
    final preview = (_formatMode && !_editing) ? parseFormat(_format.text) : null;
    // Manual rows: expand R / PP / ... for the preview and the total (invalid rows count as nothing).
    final manual = (_formatMode && !_editing) ? const <Line>[] : _merge([for (final r in _rows) ...?_rowLines(r, (_) {}, context.t)]);
    final proposed = (_formatMode && !_editing) ? preview!.result : manual;
    final blocked = d.blockedNumbers.toSet();
    final removed = proposed.where((line) => blocked.contains(line.num)).toList();
    final shown = proposed.where((line) => !blocked.contains(line.num)).toList();
    final total = shown.fold(0.0, (sum, line) => sum + line.amount);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? context.t('bets.voucher', {'code': widget.existing!.code}) : context.t('bets.new')),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
        // --- who / when / how
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: context.t('bets.user'),
                      prefixIcon: const Icon(Icons.person_outline),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    child: Text(
                      d.users.where((user) => user.id == _userId).firstOrNull?.name ??
                          context.t('common.unknown'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16)),
                  icon: const Icon(Icons.event, size: 18),
                  label: Text(_date),
                  onPressed: _editing
                      ? null
                      : () async {
                          final p = await pickDate(context, _date);
                          if (p != null) setState(() => _date = p);
                        },
                ),
              ]),
              DropdownButton<String>(
                value: _session,
                isExpanded: true,
                items: [
                  for (final session in ['morning', 'evening'])
                    DropdownMenuItem(value: session, child: Text(sessionLabel(context, session))),
                ],
                onChanged: _editing ? null : (session) {
                  if (session != null) setState(() => _session = session);
                },
              ),
              if (!_editing) ...[
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: true, icon: const Icon(Icons.notes), label: Text(context.t('bets.format'))),
                    ButtonSegment(value: false, icon: const Icon(Icons.view_list), label: Text(context.t('bets.manual'))),
                  ],
                  selected: {_formatMode},
                  onSelectionChanged: (s) => setState(() => _formatMode = s.first),
                ),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 12),
        // --- entry
        if (_formatMode && !_editing) ...[
          TextField(
            controller: _format,
            minLines: 5,
            maxLines: 12,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
            decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '12/34-500\n05R1000\n3ပါတ်200\nအပူး-1000', alignLabelWithHint: true),
            onChanged: _inputChanged,
          ),
          if (preview!.errors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(preview.errors.map((x) => trParseError(context, x)).join('\n'), style: TextStyle(color: cs.error)),
            ),
        ] else ...[
          // Column titles above the rows: ဂဏန်း | အမျိုးအစား | ငွေ
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 4, 6),
            child: Row(children: [
              SizedBox(width: 84, child: Text(context.t('bets.no'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelLarge)),
              const SizedBox(width: 8),
              if (!_editing) ...[
                SizedBox(width: 112, child: Text(context.t('bets.kind'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelLarge)),
                const SizedBox(width: 8),
              ],
              Expanded(child: Text(context.t('bets.amount'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelLarge)),
              const SizedBox(width: 40),
            ]),
          ),
          for (var i = 0; i < _rows.length; i++) _manualRow(context, i),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            onPressed: () => setState(() => _rows.add(_Row())),
            icon: const Icon(Icons.add),
            label: Text(context.t('bets.addRow')),
          ),
        ],
        if (removed.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(context.t('bets.removedTitle'), style: TextStyle(color: cs.error, fontWeight: FontWeight.bold)),
          for (final line in removed) KV(line.num, money(line.amount), color: cs.error),
        ],
        // --- what will be saved
        if (shown.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(context.t('bets.preview', {'n': shown.length}), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Opacity(
            opacity: _editing && !_editedInputs ? 0.48 : 1,
            child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final l in shown)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: cs.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: l.num, style: const TextStyle(fontWeight: FontWeight.bold)),
                  TextSpan(text: '  ${money(l.amount)}'),
                ])),
              ),
            ]),
          ),
        ],
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(8)),
            child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
          ),
      ]),
      // --- total + save, always visible
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(color: cs.surface, border: Border(top: BorderSide(color: cs.outlineVariant))),
          child: Row(children: [
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('settle.total'), style: Theme.of(context).textTheme.bodySmall),
                Text(money(total), style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
              ]),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14)),
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(context.t(_editing ? 'bets.saveChanges' : 'bets.save')),
            ),
          ]),
        ),
      ),
    );
  }

  /// One manual row: [number] [type] [amount] [remove], with what it expands to underneath.
  Widget _manualRow(BuildContext context, int i) {
    final cs = Theme.of(context).colorScheme;
    final r = _rows[i];
    final lines = _rowLines(r, (_) {}, context.t);
    final rowTotal = (lines ?? const <Line>[]).fold(0.0, (a, x) => a + x.amount);
    const field = OutlineInputBorder();
    return Container(
      key: ObjectKey(r),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 6),
      decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant), borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        Row(children: [
          // number
          SizedBox(
            width: 84,
            child: TextField(
              controller: r.num,
              enabled: !_noNumber(r.kind),
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              maxLength: _digitKind(r.kind) ? 1 : (_khweKind(r.kind) ? 20 : 2),
              // ခွေ can take any of 0–9, so use a smaller font to show more digits.
              style: TextStyle(fontSize: _khweKind(r.kind) ? 14 : 18, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                hintText: _digitKind(r.kind) ? '0–9' : (_noNumber(r.kind) ? '—' : (_khweKind(r.kind) ? '0123…' : '00')),
                counterText: '',
                isDense: true,
                border: field,
              ),
              onChanged: _inputChanged,
            ),
          ),
          const SizedBox(width: 8),
          if (!_editing) ...[
          SizedBox(
            width: 112,
            child: DropdownButtonFormField<String>(
              initialValue: r.kind,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true, border: field),
              items: [
                for (final k in _kinds)
                  DropdownMenuItem(
                    value: k,
                    child: Text(
                      context.t('kind.$k'),
                      textAlign: TextAlign.center,
                      style: k == 'num' ? TextStyle(color: Theme.of(context).colorScheme.outline) : null,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() {
                r.kind = v ?? 'num';
                if (_noNumber(r.kind)) r.num.clear();
                if (_digitKind(r.kind) && r.num.text.length > 1) r.num.clear();
                if (!_khweKind(r.kind) && r.num.text.length > 2) r.num.clear();
              }),
            ),
          ),
          const SizedBox(width: 8),
          ],
          // amount
          Expanded(
            child: TextField(
              controller: r.amount,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 16),
              decoration: const InputDecoration(hintText: '0', isDense: true, border: field),
              onChanged: _inputChanged,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: context.t('common.delete'),
            icon: Icon(Icons.close, color: _rows.length > 1 ? cs.error : null),
            onPressed: _rows.length > 1 ? () => setState(() {
              _removedRows.add(_rows.removeAt(i));
              _editedInputs = true;
            }) : null,
          ),
        ]),
        if (lines != null && lines.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.t('bets.rowExpand', {'n': lines.length, 'v': money(rowTotal)}),
                style: TextStyle(fontSize: 12, color: cs.primary),
              ),
            ),
          ),
      ]),
    );
  }
}
