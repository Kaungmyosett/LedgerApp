import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_app/api/api_client.dart';
import 'package:ledger_app/i18n/lang.dart';
import 'package:ledger_app/ledger/draw_period.dart';
import 'package:ledger_app/ledger/ledger_store.dart';
import 'package:ledger_app/ledger/models.dart';
import 'package:ledger_app/screens/ledger/bets_tab.dart';
import 'package:ledger_app/screens/ledger/history_tab.dart';
import 'package:ledger_app/screens/ledger/numbers_tab.dart';
import 'package:ledger_app/screens/ledger/users_tab.dart';
import 'package:provider/provider.dart';
import 'package:ledger_app/models/client_account.dart';
import 'package:ledger_app/util/format.dart';

void main() {
  testWidgets('Numbers hides the morning result when the period changes', (tester) async {
    final lang = Lang();
    final store = LedgerStore(
      api: ApiClient(baseUrl: 'http://test'),
      owner: 'test',
      file: File('unused-ledger-test.json'),
    );
    final morning = DateTime(2026, 11, 25, 12, 59);
    store.data = LedgerData(
      entries: [
        LEntry(id: 'v', userId: 'u', code: 'V00000001', mode: 'manual',
            date: '2026-11-25', createdAt: morning.toUtc().toIso8601String(), session: 'morning',
            lines: const [Line('00', 1000)]),
      ],
      drawResults: const [
        LDraw(date: '2026-11-24', session: 'evening', number: '19'),
        LDraw(date: '2026-11-25', session: 'morning', number: '25'),
      ],
    );
    Widget app(DateTime time) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: lang),
        ChangeNotifierProvider.value(value: store),
        Provider<DrawPeriod>.value(value: drawPeriodAt(time)),
      ],
      child: const MaterialApp(home: Scaffold(body: NumbersTab())),
    );
    await tester.pumpWidget(app(morning));
    expect(find.text('ထွက်ဂဏန်း'), findsOneWidget);
    await tester.pumpWidget(app(DateTime(2026, 11, 25, 13)));
    expect(find.text('ထွက်ဂဏန်း'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
    lang.dispose();
  });

  testWidgets('Voucher numbers has its own action between settlement and edit', (tester) async {
    final lang = Lang();
    final store = LedgerStore(
      api: ApiClient(baseUrl: 'http://test'),
      owner: 'test',
      file: File('unused-ledger-test.json'),
    );
    final morning = DateTime(2026, 11, 25, 10);
    store.data = LedgerData(
      users: const [
        LUser(id: 'a', name: 'May', username: 'may', commissionPercent: 10, odd: 80),
      ],
      entries: [
        for (final (id, userId, amount) in [('v1', 'a', 1000.0), ('v2', 'a', 200.0), ('v3', 'b', 3000.0)])
          LEntry(id: id, userId: userId, code: '', mode: 'manual',
              date: '2026-11-25', createdAt: morning.toUtc().toIso8601String(), session: 'morning',
              lines: [Line('00', amount)]),
      ],
    );
    String? copied;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: lang),
        ChangeNotifierProvider.value(value: store),
        Provider<DrawPeriod>.value(value: drawPeriodAt(morning)),
      ],
      child: const MaterialApp(home: UsersTab()),
    ));

    final settlement = find.text(lang.get('users.settlement'));
    final vouchers = find.text(lang.get('users.voucherNumbers'));
    final edit = find.text(lang.get('common.edit'));
    final copy = find.text(lang.get('common.copy'));

    await tester.tap(find.text('May'));
    await tester.pumpAndSettle();
    expect(tester.getCenter(settlement).dy, lessThan(tester.getCenter(vouchers).dy));
    expect(tester.getCenter(vouchers).dy, lessThan(tester.getCenter(edit).dy));

    await tester.tap(settlement);
    await tester.pumpAndSettle();
    expect(find.text(lang.get('settle.title', {'name': 'May'})), findsOneWidget);
    expect(vouchers, findsNothing);
    expect(copy, findsNothing);
    await tester.tap(find.text(lang.get('common.close')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('May'));
    await tester.pumpAndSettle();
    await tester.tap(vouchers);
    await tester.pumpAndSettle();
    expect(vouchers, findsOneWidget);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copied, contains('00\t1,200'));
    expect(copied, contains("${lang.get('money.commission')} = 120"));
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
    lang.dispose();
  });

  testWidgets('Voucher creation is available only from the selected commission user', (tester) async {
    final lang = Lang();
    final store = LedgerStore(
      api: ApiClient(baseUrl: 'http://test'),
      owner: 'test',
      file: File('unused-ledger-test.json'),
    );
    store.data = LedgerData(users: const [
      LUser(id: 'a', name: 'May', username: 'may', commissionPercent: 10, odd: 80),
      LUser(id: 'b', name: 'Aung', username: 'aung', commissionPercent: 10, odd: 80),
    ]);

    Widget app(Widget tab) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: lang),
        ChangeNotifierProvider.value(value: store),
      ],
      child: MaterialApp(home: tab),
    );
    await tester.pumpWidget(app(const BetsTab()));
    expect(find.byType(FloatingActionButton), findsNothing);

    await tester.pumpWidget(app(const UsersTab()));
    final userTile = find.ancestor(of: find.text('May'), matching: find.byType(ListTile));
    await tester.tap(find.descendant(of: userTile, matching: find.byIcon(Icons.add)));
    await tester.pumpAndSettle();
    expect(find.text(lang.get('bets.new')), findsOneWidget);
    expect(find.text('May'), findsOneWidget);
    expect(find.text('Aung'), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
    lang.dispose();
  });

  testWidgets('Commission totals open vouchers for the selected user and draw period', (tester) async {
    final lang = Lang();
    final store = LedgerStore(
      api: ApiClient(baseUrl: 'http://test'),
      owner: 'test',
      file: File('unused-ledger-test.json'),
    );
    final morning = DateTime(2026, 11, 25, 10);
    final evening = DateTime(2026, 11, 25, 15);
    LEntry entry(String code, String user, DateTime time) => LEntry(
      id: code, userId: user, code: code, mode: 'manual', date: ledgerDate(time),
      createdAt: time.toUtc().toIso8601String(), session: drawSession(time), lines: const [Line('25', 100)],
    );
    store.data = LedgerData(
      users: const [
        LUser(id: 'a', name: 'May', username: 'may', commissionPercent: 10, odd: 80, payment: 40),
        LUser(id: 'b', name: 'Aung', username: 'aung', commissionPercent: 10, odd: 80),
      ],
      entries: [
        entry('Morning', 'a', morning),
        entry('My evening A', 'a', evening),
        entry('My evening B', 'a', evening),
        entry('Someone else', 'b', evening),
      ],
      drawResults: [
        LDraw(date: ledgerDate(morning), session: 'morning', number: '25'),
        LDraw(date: ledgerDate(evening), session: 'evening', number: '57'),
      ],
    );
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: lang),
        ChangeNotifierProvider.value(value: store),
        Provider<DrawPeriod>.value(value: drawPeriodAt(morning)),
      ],
      child: const MaterialApp(home: UsersTab()),
    ));
    expect(find.text(lang.get('settle.number', {'n': '25'})), findsOneWidget);
    expect(find.text(lang.get('money.payment')), findsOneWidget);
    await tester.tap(find.text(lang.get('common.evening')));
    await tester.pumpAndSettle();
    expect(find.text(lang.get('settle.number', {'n': '57'})), findsOneWidget);
    final card = find.ancestor(of: find.text('May'), matching: find.byType(Card));
    await tester.tap(find.descendant(of: card, matching: find.text(lang.get('settle.total'))));
    await tester.pumpAndSettle();
    expect(find.textContaining('My evening'), findsNWidgets(2));
    expect(find.textContaining('Someone else'), findsNothing);
    expect(find.textContaining('Morning'), findsNothing);

    await tester.tap(find.text(lang.get('vouchers.select')));
    await tester.pumpAndSettle();
    final checkbox = find.byType(Checkbox);
    expect(checkbox, findsNWidgets(2));
    await tester.tap(checkbox.first);
    await tester.tap(checkbox.last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(lang.get('vouchers.deleteSelected', {'n': 2})));
    await tester.pumpAndSettle();
    expect(find.text(lang.get('vouchers.deleteBody', {'n': 2})), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
    lang.dispose();
  });

  testWidgets('Weekly history expands individual and all-user reports separately', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final lang = Lang();
    final store = LedgerStore(
      api: ApiClient(baseUrl: 'http://test'),
      owner: 'test',
      file: File('unused-ledger-test.json'),
    );
    final now = DateTime.now();
    final monday = ledgerDate(DateTime(now.year, now.month, now.day - now.weekday + 1));
    LFinal record(String user, String session, double stake) => LFinal(
        id: '$user-$session', userId: user, userName: user, date: monday,
        session: session, number: session == 'morning' ? '25' : '57',
        total: stake, winAmount: 1, odd: 80, payout: 80,
        commission: stake / 10, payment: 0, net: stake * .9 - 80, createdAt: '',
        covered: 789, eaten: 456);
    store.data = LedgerData(finalizedRecords: [
      record('May', 'morning', 1000),
      record('May', 'evening', 1200),
      record('Aung', 'morning', 2000),
    ]);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: lang),
        ChangeNotifierProvider.value(value: store),
      ],
      child: const MaterialApp(home: Scaffold(body: HistoryTab())),
    ));
    await tester.tap(find.text(lang.get('hist.weekly')));
    await tester.pumpAndSettle();
    expect(find.text(lang.get('hist.weekTotal')), findsNothing);

    final total = find.text(lang.get('hist.allTotal'));
    await tester.tap(total);
    await tester.pumpAndSettle();
    expect(find.text(lang.get('hist.weekTotal')), findsOneWidget);
    for (final value in ['4,200', '3,000', '1,200', '2,367', '1,368', '240', '160', '(2 × 80)', '80', '(1 × 80)', '25', '57']) {
      expect(find.text(value), findsOneWidget, reason: value);
    }
    expect(
      tester.getTopLeft(find.text('160')).dy,
      lessThan(tester.getTopLeft(find.text('(2 × 80)')).dy),
    );
    expect(tester.takeException(), isNull);
    final export = find.text(lang.get('hist.exportImage'));
    expect(export, findsOneWidget);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const share = MethodChannel('dev.fluttercommunity.plus/share');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final tmp = Directory.systemTemp.createTempSync('weekly-export-test');
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathProvider, null);
      messenger.setMockMethodCallHandler(share, null);
      tmp.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      final exported = Completer<List<int>>();
      messenger.setMockMethodCallHandler(pathProvider, (_) async => tmp.path);
      messenger.setMockMethodCallHandler(share, (call) async {
        final args = call.arguments as Map;
        final path = (args['paths'] as List).single as String;
        exported.complete(File(path).readAsBytesSync());
        return 'test-target';
      });
      await tester.tap(export);
      final bytes = await exported.future.timeout(const Duration(seconds: 5));
      expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final width = bytes.sublist(16, 20).fold(0, (int total, byte) => total * 256 + byte);
      expect(width, greaterThan(1400));

      final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
      final image = (await codec.getNextFrame()).image;
      try {
        final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        int red(int x, int y) => rgba.getUint8((y * width + x) * 4);
        final headerTop = Iterable<int>.generate(image.height).firstWhere((y) => red(26, y) == 0xe4);
        final headerBottom = Iterable<int>.generate(image.height - headerTop, (i) => headerTop + i)
            .firstWhere((y) => red(26, y) == 0xff);
        final lastColumnRight = width - 24;
        final lastColumnLeft = lastColumnRight - 201;
        final center = (lastColumnLeft + lastColumnRight) / 2;

        double inkCenter(int firstRow, int lastRow) {
          int? first, last;
          for (var x = lastColumnLeft; x < lastColumnRight; x++) {
            for (var y = firstRow; y < lastRow; y++) {
              if (red(x, y) < 100) {
                first ??= x;
                last = x;
                break;
              }
            }
          }
          return (first! + last!) / 2;
        }

        expect(inkCenter(headerTop, headerBottom), closeTo(center, 8));
        expect(inkCenter(headerBottom, headerBottom + 45), closeTo(center, 8));
      } finally {
        image.dispose();
        codec.dispose();
      }
    });
    await tester.pumpAndSettle();

    await tester.tap(total);
    await tester.pumpAndSettle();
    await tester.tap(find.text('May'));
    await tester.pumpAndSettle();
    expect(find.text(lang.get('hist.weekTotal')), findsOneWidget);
    expect(find.text('2,200'), findsOneWidget);
    expect(find.text('160'), findsOneWidget);
    expect(find.text('(1 × 80)'), findsNWidgets(2));
    expect(find.text('25'), findsOneWidget);
    expect(find.text('57'), findsOneWidget);
    expect(find.text(lang.get('num.totalCover')), findsNothing);
    expect(find.text(lang.get('num.totalEaten')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
    lang.dispose();
  });

  test('ClientAccount parses the API shape', () {
    final c = ClientAccount.fromJson({
      'id': 'abc',
      'displayName': 'Ko Aung',
      'email': 'aung@example.com',
      'isActive': true,
      'loginCodeExpiresAt': '2026-11-19T08:00:00.000Z',
      'lastLoginAt': null,
    });
    expect(c.displayName, 'Ko Aung');
    expect(c.email, 'aung@example.com');
    expect(c.isActive, isTrue);
    expect(c.loginCodeExpiresAt, isNotNull);
    expect(c.lastLoginAt, isNull);
  });

  test('ClientAccount works for /v1/client/me (no isActive, no code fields)', () {
    final c = ClientAccount.fromJson({'id': 'abc', 'displayName': 'Ko Aung', 'email': 'aung@example.com'});
    expect(c.isActive, isTrue);
    expect(c.loginCodeExpiresAt, isNull);
  });

  test('spaceCode groups a 6-digit code', () {
    expect(spaceCode('042917'), '042 917');
    expect(spaceCode('123'), '123');
  });

  test('formatDateTime pads fields', () {
    expect(formatDateTime(DateTime(2026, 1, 5, 7, 3)), '2026-01-05 07:03');
  });

  test('describeError joins validation details', () {
    final e = ApiException(400, 'VALIDATION_ERROR', 'x', ['email: Invalid email address']);
    expect(describeError(e), 'email: Invalid email address');
    expect(describeError(NetworkException()), contains('Cannot reach'));
  });
}
