import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'strings.dart';

/// App language: 'my' (Myanmar, default) or 'en'. Saved in a small file on the phone
/// (not in the secure storage, which must not be read from two places at once at startup).
class Lang extends ChangeNotifier {
  String code = 'my';

  Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}/app_lang.txt');

  bool get isMy => code == 'my';

  Future<void> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final v = (await f.readAsString()).trim();
        if (v == 'en' || v == 'my') code = v;
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> set(String c) async {
    if (c == code) return;
    code = c;
    notifyListeners();
    try {
      await (await _file()).writeAsString(c, flush: true);
    } catch (_) {}
  }

  Future<void> toggle() => set(isMy ? 'en' : 'my');

  /// Translation for [key]; `{name}` placeholders are filled from [args]. Falls back to English, then the key.
  String get(String key, [Map<String, Object?> args = const {}]) {
    var s = (code == 'my' ? myStrings[key] : null) ?? enStrings[key] ?? key;
    args.forEach((k, v) => s = s.replaceAll('{$k}', '${v ?? ''}'));
    return s;
  }
}

extension Tr on BuildContext {
  /// Translate. Safe to call in build methods and in callbacks.
  String t(String key, [Map<String, Object?> args = const {}]) => Provider.of<Lang>(this, listen: false).get(key, args);
  Lang get lang => Provider.of<Lang>(this, listen: false);
}

/// Parser messages come from the original HTML in Myanmar; shown in English when English is selected.
String trParseError(BuildContext c, String msg) {
  if (c.lang.isMy) return msg;
  const map = {
    'PP / TO / BO / BR တွင် 0 မှ 9 အထိ digit သာသုံးပါ: ': 'PP / TO / BO / BK take a single digit 0–9: ',
    'ဂဏန်း သို့မဟုတ် ငွေပမာဏ မမှန်ပါ: ': 'Invalid number or amount: ',
    'ဂဏန်း format မမှန်ပါ: ': 'Invalid number format: ',
    'Format မမှန်ပါ: ': 'Invalid format: ',
  };
  for (final e in map.entries) {
    if (msg.startsWith(e.key)) return e.value + msg.substring(e.key.length);
  }
  return msg;
}

/// Message for a ledger rule / server error code.
String trRule(BuildContext c, String code, String fallback, [Map<String, Object?> args = const {}]) {
  final k = 'err.$code';
  final s = c.t(k, args);
  return s == k ? fallback : s;
}
