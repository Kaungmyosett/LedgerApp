import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_app/i18n/lang.dart';
import 'package:ledger_app/i18n/strings.dart';

void main() {
  test('Myanmar and English have the same keys', () {
    expect(myStrings.keys.toSet(), enStrings.keys.toSet());
  });

  test('placeholders are filled and language switches', () {
    final l = Lang();
    expect(l.get('tab.history'), 'မှတ်တမ်းများ');
    expect(l.get('num.active', {'n': 3}), 'Active ဂဏန်း 3 / 100');
    l.code = 'en';
    expect(l.get('num.active', {'n': 3}), 'Active numbers 3 / 100');
    expect(l.get('no.such.key'), 'no.such.key');
  });

  test('every placeholder in English also exists in Myanmar', () {
    final re = RegExp(r'\{(\w+)\}');
    for (final k in enStrings.keys) {
      final en = re.allMatches(enStrings[k]!).map((m) => m.group(1)).toSet();
      final my = re.allMatches(myStrings[k]!).map((m) => m.group(1)).toSet();
      expect(my, en, reason: k);
    }
  });
}
