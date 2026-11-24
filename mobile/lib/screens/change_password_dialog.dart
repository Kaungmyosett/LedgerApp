import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_state.dart';
import '../i18n/lang.dart';
import '../util/format.dart';

Future<void> showChangePasswordDialog(BuildContext context) async {
  final done = await showDialog<bool>(context: context, builder: (_) => const _ChangePasswordDialog());
  if (done == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t('pw.changed'))));
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AuthState>().changePassword(_current.text, _next.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t('pw.title')),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _current,
              obscureText: true,
              decoration: InputDecoration(labelText: context.t('pw.current')),
              validator: (v) => (v == null || v.isEmpty) ? context.t('common.required') : null,
            ),
            TextFormField(
              controller: _next,
              obscureText: true,
              decoration: InputDecoration(labelText: context.t('pw.new')),
              validator: (v) => (v == null || v.length < 12) ? context.t('pw.short') : null,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(context.t('common.cancel'))),
        FilledButton(onPressed: _busy ? null : _save, child: Text(context.t('common.save'))),
      ],
    );
  }
}
