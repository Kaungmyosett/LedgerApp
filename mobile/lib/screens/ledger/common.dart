import 'package:flutter/material.dart';

import '../../i18n/lang.dart';
import '../../ledger/ledger_store.dart';
import '../../ledger/ops.dart';

/// 1234567 -> "1,234,567"; 12.5 -> "12.5" (at most 2 decimals, no trailing zeros).
String money(double v) {
  final neg = v < 0;
  var s = v.abs().toStringAsFixed(2);
  if (s.endsWith('.00')) {
    s = s.substring(0, s.length - 3);
  } else if (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  final parts = s.split('.');
  final intPart = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${neg ? '-' : ''}$intPart${parts.length > 1 ? '.${parts[1]}' : ''}';
}

String sessionLabel(BuildContext c, String s) => c.t(s == 'morning' ? 'common.morning' : 'common.evening');

/// Parses an amount typed by the user: digits with an optional 1–2 decimals. Null when invalid or not above zero.
double? parseAmount(String raw) {
  final t = raw.trim().replaceAll(',', '');
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(t)) return null;
  final v = double.parse(t);
  return v > 0 ? v : null;
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

Future<bool> confirmDialog(BuildContext context, String title, String body, String action, {bool danger = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('common.cancel'))),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Date picker returning 'YYYY-MM-DD'.
/// Dates after today are not allowed (a voucher or draw result can't be for a day that hasn't come yet).
Future<String?> pickDate(BuildContext context, String current) async {
  final now = DateTime.now();
  final last = DateTime(now.year, now.month, now.day);
  var cur = DateTime.tryParse(current) ?? last;
  if (cur.isAfter(last)) cur = last;
  final d = await showDatePicker(context: context, initialDate: cur, firstDate: DateTime(2020), lastDate: last);
  if (d == null) return null;
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class KV extends StatelessWidget {
  const KV(this.k, this.v, {super.key, this.bold = false, this.color, this.valueDetail});
  final String k;
  final String v;
  final String? valueDetail;
  final bool bold;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final st = TextStyle(fontWeight: bold ? FontWeight.bold : null, color: color);
    final detail = valueDetail;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: detail == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: Text(k)),
          const SizedBox(width: 8),
          if (detail == null)
            Text(v, style: st)
          else
            Expanded(flex: 2, child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(v, textAlign: TextAlign.end, style: st),
                Text(detail, textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodySmall),
              ],
            )),
        ],
      ),
    );
  }
}

/// Runs a ledger change; if the rules refuse it (blocked number, plan ended, offline too long, ...)
/// shows the reason and returns false instead of throwing.
Future<bool> runOrToast(BuildContext context, LedgerStore store, Op op) async {
  try {
    await store.run(op);
    return true;
  } on LedgerRule catch (e) {
    if (context.mounted) toast(context, trRule(context, e.code, e.message));
    return false;
  }
}

/// Queues a confirmed voucher selection through the normal offline sync path.
Future<bool> deleteVouchers(
  BuildContext context,
  LedgerStore store,
  List<Op> ops, {
  required String title,
  required String body,
}) async {
  if (ops.isEmpty) return false;
  final confirmed = await confirmDialog(context, title, body, context.t('common.delete'), danger: true);
  if (!confirmed || !context.mounted) return false;
  try {
    await store.runAll(ops);
    return true;
  } on LedgerRule catch (e) {
    if (context.mounted) toast(context, trRule(context, e.code, e.message));
    return false;
  }
}

class VoucherSelectionBar extends StatelessWidget {
  const VoucherSelectionBar({
    super.key, required this.selecting, required this.count,
    required this.toggle, required this.delete,
  });

  final bool selecting;
  final int count;
  final VoidCallback toggle, delete;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Wrap(spacing: 8, children: [
      TextButton.icon(
        icon: Icon(selecting ? Icons.close : Icons.checklist),
        label: Text(context.t(selecting ? 'common.cancel' : 'vouchers.select')),
        onPressed: toggle,
      ),
      if (selecting)
        TextButton.icon(
          icon: const Icon(Icons.delete_outline),
          label: Text(context.t('vouchers.deleteSelected', {'n': count})),
          onPressed: count == 0 ? null : delete,
        ),
    ]),
  );
}

String payoutFormula(double stake, double odd) => '${money(stake)} × ${money(odd)}';

Widget payoutRow(BuildContext context, double amount, double stake, double odd, {bool bold = false, Color? color}) =>
    KV(context.t('money.payout'), money(amount), bold: bold, color: color,
        valueDetail: '(${payoutFormula(stake, odd)})');
