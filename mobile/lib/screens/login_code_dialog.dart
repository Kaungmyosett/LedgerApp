import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/lang.dart';
import '../util/format.dart';

/// Shows a freshly issued login code. The server cannot show it again, so the Admin must pass it on now.
Future<void> showLoginCodeDialog(
  BuildContext context, {
  required String clientName,
  required String code,
  required DateTime expiresAt,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.t('code.title', {'name': clientName})),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            spaceCode(code),
            style: Theme.of(ctx).textTheme.displaySmall?.copyWith(letterSpacing: 4, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Text(
            ctx.t('code.body', {'name': clientName, 'time': formatDateTime(expiresAt)}),
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy),
          label: Text(ctx.t('common.copy')),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(ctx.t('code.copied'))));
            }
          },
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.t('common.done'))),
      ],
    ),
  );
}
