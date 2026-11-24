import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_app/api/api_client.dart';
import 'package:ledger_app/models/client_account.dart';
import 'package:ledger_app/util/format.dart';

void main() {
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
