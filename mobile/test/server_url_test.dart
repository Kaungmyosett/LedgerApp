import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_app/util/server_url.dart';

void main() {
  test('server address is cleaned up', () {
    expect(cleanServerUrl('abc-def.trycloudflare.com/'), 'https://abc-def.trycloudflare.com');
    expect(cleanServerUrl(' https://abc.trycloudflare.com// '), 'https://abc.trycloudflare.com');
    expect(cleanServerUrl('http://192.168.1.20:3000'), 'http://192.168.1.20:3000');
    expect(cleanServerUrl(''), isNull);
    expect(cleanServerUrl('https://'), isNull);
  });
}
