import 'models.dart';

String ledgerDate(DateTime time) => time.toIso8601String().split('T').first;

String drawSession(DateTime time) => time.hour < 13 ? 'morning' : 'evening';

typedef DrawPeriod = ({String date, String session});

DrawPeriod drawPeriodAt(DateTime time) =>
    (date: ledgerDate(time), session: drawSession(time));

DateTime nextDrawPeriod(DateTime time) => time.hour < 13
    ? DateTime(time.year, time.month, time.day, 13)
    : DateTime(time.year, time.month, time.day + 1);

bool _inPeriod(String date, String createdAt, DrawPeriod period) {
  if (date != period.date) return false;
  final created = DateTime.tryParse(createdAt)?.toLocal();
  return created != null && drawSession(created) == period.session;
}

extension DrawPeriodData on LedgerData {
  List<LEntry> entriesFor(DrawPeriod period) =>
      entries.where((e) => _inPeriod(e.date, e.createdAt, period)).toList();

  List<LCover> coversFor(DrawPeriod period) =>
      coverVouchers.where((v) => _inPeriod(v.date, v.createdAt, period)).toList();

  LDraw? drawFor(DrawPeriod period) => drawResults.where((draw) =>
      draw.date == period.date &&
      draw.session == period.session &&
      draw.number.isNotEmpty).firstOrNull;
}
