import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_app/util/email.dart';

void main() {
  test('email format (same cases as the server test)', () {
    expect(normalizeEmail('  Foo@Example.COM '), 'foo@example.com');
    for (final ok in ['ko.aung@gmail.com', 'a@b.co', 'user+tag@mail.example.com.mm', 'x_y-z@my-domain.org']) {
      expect(normalizeEmail(ok), ok, reason: ok);
    }
    for (final bad in ['not-an-email', 'a b@x.com', 'a@b', 'a@b.c', '.a@b.com', 'a.@b.com', 'a..b@c.com', 'a@-b.com', 'a@b-.com',
      'a@b..com', 'a@@b.com', 'a@b.com.', '@b.com', 'a@.com', 'a@b.c0m', 'ကို@gmail.com', 'a,b@c.com', 'a@b_c.com', '${'x' * 65}@b.com']) {
      expect(normalizeEmail(bad), isNull, reason: bad);
    }
  });
}
