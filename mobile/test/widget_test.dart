import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_app/api/api_client.dart';
import 'package:ledger_app/i18n/lang.dart';
import 'package:ledger_app/ledger/draw_period.dart';
import 'package:ledger_app/ledger/ledger_store.dart';
import 'package:ledger_app/ledger/models.dart';
import 'package:ledger_app/screens/ledger/numbers_tab.dart';
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
            date: '2026-11-25', createdAt: morning.toUtc().toIso8601String(),
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
