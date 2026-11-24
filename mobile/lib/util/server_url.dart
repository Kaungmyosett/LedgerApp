import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../config.dart';
import '../i18n/lang.dart';

/// The server address can be changed inside the app (v0.7.3), so a new Cloudflare tunnel address
/// does not need a new APK. Saved in a small file; empty = the built-in address (API_URL / development default).
Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}/server_url.txt');

Future<String?> loadServerUrl() async {
  try {
    final f = await _file();
    if (!await f.exists()) return null;
    final v = (await f.readAsString()).trim();
    return v.isEmpty ? null : v;
  } catch (_) {
    return null;
  }
}

Future<void> saveServerUrl(String? url) async {
  try {
    final f = await _file();
    if (url == null || url.isEmpty) {
      if (await f.exists()) await f.delete();
    } else {
      await f.writeAsString(url, flush: true);
    }
  } catch (_) {}
}

/// "abc.trycloudflare.com/" -> "https://abc.trycloudflare.com". Null when it is not a usable address.
String? cleanServerUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty || u.host.contains(' ')) return null;
  return s;
}

/// Dialog: shows the current address, lets the user paste a new one, test it (GET /health) and save it.
Future<void> showServerDialog(BuildContext context) async {
  final api = context.read<ApiClient>();
  final c = TextEditingController(text: api.baseUrl);
  String? status;
  bool? ok;
  bool busy = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      Future<bool> test(String url) async {
        setS(() {
          busy = true;
          status = null;
        });
        try {
          final res = await http.get(Uri.parse('$url/health')).timeout(const Duration(seconds: 10));
          ok = res.statusCode == 200;
          status = ok! ? ctx.t('server.ok') : ctx.t('server.bad', {'code': res.statusCode});
        } catch (_) {
          ok = false;
          status = ctx.t('server.unreachable');
        }
        setS(() => busy = false);
        return ok!;
      }

      return AlertDialog(
        title: Text(ctx.t('server.title')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: c,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(labelText: ctx.t('server.url'), hintText: 'https://xxxx.trycloudflare.com', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Text(ctx.t('server.help'), style: Theme.of(ctx).textTheme.bodySmall),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(status!, style: TextStyle(color: ok == true ? Colors.green.shade700 : Colors.red.shade700, fontWeight: FontWeight.w600)),
            ),
        ]),
        actions: [
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    // Back to the built-in address.
                    await saveServerUrl(null);
                    api.baseUrl = apiBaseUrl;
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
            child: Text(ctx.t('server.reset')),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () {
                    final u = cleanServerUrl(c.text);
                    if (u == null) return setS(() => status = ctx.t('server.invalid'));
                    c.text = u;
                    test(u);
                  },
            child: Text(ctx.t('server.test')),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    final u = cleanServerUrl(c.text);
                    if (u == null) return setS(() => status = ctx.t('server.invalid'));
                    await saveServerUrl(u);
                    api.baseUrl = u;
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
            child: Text(ctx.t('common.save')),
          ),
        ],
      );
    }),
  );
}
