import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../i18n/lang.dart';
import '../../ledger/models.dart';
import 'common.dart';

class WeeklyReportCard extends StatefulWidget {
  const WeeklyReportCard({
    super.key,
    required this.title,
    required this.days,
    required this.records,
    required this.drawsByDate,
    this.showCoverAmounts = false,
  });

  final String title;
  final List<String> days;
  final List<LFinal> records;
  final Map<String, Map<String, String>> drawsByDate;
  final bool showCoverAmounts;

  @override
  State<WeeklyReportCard> createState() => _WeeklyReportCardState();
}

class _WeeklyReportCardState extends State<WeeklyReportCard> {
  bool _sharing = false;

  List<String> _row(String date, String day, String session, String winning,
      List<LFinal> records) {
    String sum(double? Function(LFinal) value) {
      if (records.isEmpty) return '—';
      var total = 0.0;
      for (final record in records) {
        final amount = value(record);
        if (amount == null) return '—';
        total += amount;
      }
      return money(total);
    }

    final payout = sum((r) => r.payout);
    final winningByOdd = <double, double>{};
    if (session.isNotEmpty) {
      for (final record in records) {
        if (record.winAmount > 0) {
          winningByOdd.update(record.odd, (stake) => stake + record.winAmount,
              ifAbsent: () => record.winAmount);
        }
      }
    }
    final calculation = winningByOdd.entries
        .map((entry) => payoutFormula(entry.value, entry.key))
        .join(' + ');

    return [
      date,
      day,
      session,
      winning,
      sum((r) => r.total),
      sum((r) => r.commission),
      calculation.isEmpty ? payout : '$payout\n($calculation)',
      if (widget.showCoverAmounts) ...[
        sum((r) => r.covered),
        sum((r) => r.eaten),
      ],
      sum((r) => r.net),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final byPeriod = <(String, String), List<LFinal>>{};
    for (final record in widget.records) {
      byPeriod.putIfAbsent((record.date, record.session), () => []).add(record);
    }
    final columns = [
      (key: 'hist.date', width: 218.0),
      (key: 'hist.day', width: 112.0),
      (key: 'hist.session', width: 112.0),
      (key: 'num.winning', width: 136.0),
      (key: 'money.total', width: 158.0),
      (key: 'money.commission', width: 183.0),
      (key: 'money.payout', width: 300.0),
      if (widget.showCoverAmounts) ...[
        (key: 'num.totalCover', width: 158.0),
        (key: 'num.totalEaten', width: 158.0),
      ],
      (key: 'money.net', width: 201.0),
    ];
    final headers = [for (final column in columns) context.t(column.key)];
    final widths = [for (final column in columns) column.width];

    final rows = [
      for (final (index, date) in widget.days.indexed)
        for (final session in ['morning', 'evening'])
          _row(
            date,
            context.t('hist.weekday${index + 1}'),
            sessionLabel(context, session),
            widget.drawsByDate[date]?[session] ?? '—',
            byPeriod[(date, session)] ?? const [],
          ),
      _row(context.t('hist.weekTotal'), '', '', '', widget.records),
    ];
    final period = '${widget.days.first} – ${widget.days.last}';
    return Card(
      child: ExpansionTile(
        title: Text(widget.title),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Wrap(spacing: 8, children: [
              TextButton.icon(
                icon: const Icon(Icons.copy),
                label: Text(context.t('common.copy')),
                onPressed: () async {
                  final text = [
                    widget.title,
                    period,
                    headers.join('\t'),
                    for (final row in rows)
                      row.map((cell) => cell.replaceAll('\n', ' ')).join('\t'),
                  ].join('\n');
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) toast(context, context.t('hist.copied'));
                },
              ),
              Builder(builder: (buttonContext) {
                return TextButton.icon(
                  icon: const Icon(Icons.image_outlined),
                  label: Text(context.t('hist.exportImage')),
                  onPressed: _sharing
                      ? null
                      : () => _shareImage(
                          buttonContext, period, headers, widths, rows),
                );
              }),
            ]),
          ),
          for (var day = 0; day < widget.days.length; day++)
            _dayPanel(context, headers, rows[day * 2], rows[day * 2 + 1]),
          _totalPanel(context, headers, rows.last),
        ],
      ),
    );
  }

  Widget _dayPanel(
    BuildContext context,
    List<String> headers,
    List<String> morning,
    List<String> evening,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${morning[1]} · ${morning[0]}',
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, constraints) {
          final am = _sessionPanel(context, headers, morning);
          final pm = _sessionPanel(context, headers, evening);
          if (constraints.maxWidth >= 650) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: am),
              const SizedBox(width: 16),
              Expanded(child: pm),
            ]);
          }
          return Column(children: [am, const SizedBox(height: 10), pm]);
        }),
      ]),
    );
  }

  Widget _sessionPanel(
      BuildContext context, List<String> headers, List<String> row) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hasHistory = row.skip(4).any((value) => value != '—');
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(row[2], style: theme.textTheme.titleSmall),
        if (row[3] != '—')
          KV(headers[3], row[3], bold: true, color: colors.primary),
        if (hasHistory)
          for (var column = 4; column < headers.length; column++)
            _metric(headers[column], row[column],
                bold: column == headers.length - 1)
        else
          Text(context.t('hist.noSession'), style: theme.textTheme.bodySmall),
      ]),
    );
  }

  Widget _totalPanel(
      BuildContext context, List<String> headers, List<String> row) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(row.first, style: theme.textTheme.titleSmall),
        for (var column = 4; column < headers.length; column++)
          _metric(headers[column], row[column],
              bold: column == headers.length - 1),
      ]),
    );
  }

  Widget _metric(String title, String value, {required bool bold}) {
    final lines = value.split('\n');
    return KV(title, lines.first,
        bold: bold, valueDetail: lines.length > 1 ? lines.last : null);
  }

  Future<void> _shareImage(
    BuildContext buttonContext,
    String period,
    List<String> headers,
    List<double> columnWidths,
    List<List<String>> rows,
  ) async {
    setState(() => _sharing = true);
    final box = buttonContext.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero) & box.size;
    final title = widget.title;
    final monday = widget.days.first;
    try {
      final image =
          await _reportPng(title, period, headers, columnWidths, rows);
      if (!mounted || !buttonContext.mounted) return;
      await Share.shareXFiles(
        [XFile.fromData(image, mimeType: 'image/png')],
        fileNameOverrides: ['2d-ledger-$monday.png'],
        subject: '$title · $period',
        sharePositionOrigin: origin,
      );
    } catch (_) {
      if (mounted) toast(context, context.t('hist.exportFailed'));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
}

Future<Uint8List> _reportPng(
  String title,
  String period,
  List<String> headers,
  List<double> columnWidths,
  List<List<String>> rows,
) async {
  const padding = 24.0;
  final width =
      columnWidths.fold(padding * 2, (total, column) => total + column);
  const ink = Color(0xff1c2737);
  const accent = Color(0xffe4edf8);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  var top = padding;

  TextPainter measure(String text, double size, double maxWidth,
      {bool bold = false, bool centered = false}) {
    return TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
            color: ink,
            fontSize: size,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          )),
      textDirection: TextDirection.ltr,
      textAlign: centered ? TextAlign.center : TextAlign.start,
    )..layout(minWidth: centered ? maxWidth : 0, maxWidth: maxWidth);
  }

  void caption(String text, double size, {bool bold = false}) {
    final painter = measure(text, size, width - padding * 2, bold: bold);
    painter.paint(canvas, Offset(padding, top));
    top += painter.height + 8;
    painter.dispose();
  }

  void tableRow(List<String> cells, {bool bold = false, bool shaded = false}) {
    final painters = [
      for (final (i, text) in cells.indexed)
        measure(text, 20, columnWidths[i] - 20, bold: bold, centered: true),
    ];
    var height = 50.0;
    for (final painter in painters) {
      if (painter.height + 20 > height) height = painter.height + 20;
    }
    final bounds = Rect.fromLTWH(padding, top, width - padding * 2, height);
    if (shaded) canvas.drawRect(bounds, Paint()..color = accent);
    var left = padding;
    for (final (i, painter) in painters.indexed) {
      painter.paint(
          canvas, Offset(left + 10, top + (height - painter.height) / 2));
      left += columnWidths[i];
      painter.dispose();
    }
    top += height;
    canvas.drawLine(Offset(padding, top), Offset(width - padding, top),
        Paint()..color = accent);
  }

  canvas.drawColor(Colors.white, BlendMode.src);
  caption(title, 32, bold: true);
  caption(period, 21);
  top += 8;
  tableRow(headers, bold: true, shaded: true);
  for (final row in rows) {
    final isTotal = identical(row, rows.last);
    tableRow(row, bold: isTotal, shaded: isTotal);
  }

  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(width.toInt(), (top + padding).ceil());
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw StateError('Could not encode weekly report');
      return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}
