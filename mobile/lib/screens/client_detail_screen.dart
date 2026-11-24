import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../i18n/lang.dart';
import '../models/client_account.dart';
import '../util/format.dart';
import 'client_form_screen.dart';
import 'login_code_dialog.dart';

class ClientDetailScreen extends StatefulWidget {
  const ClientDetailScreen({super.key, required this.client});
  final ClientAccount client;

  @override
  State<ClientDetailScreen> createState() => _ClientDetailScreenState();
}

class _ClientDetailScreenState extends State<ClientDetailScreen> {
  late ClientAccount _c = widget.client;
  bool _changed = false; // tells the list to refresh when we go back

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.t('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _reload() async {
    try {
      final j = await context.read<ApiClient>().get('/v1/admin/clients/${_c.id}') as Map<String, dynamic>;
      if (mounted) setState(() => _c = ClientAccount.fromJson(j));
    } catch (e) {
      if (mounted) _toast(describeError(e));
    }
  }

  Future<void> _edit() async {
    final saved = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => ClientFormScreen(existing: _c)));
    if (saved == true) {
      _changed = true;
      await _reload();
    }
  }

  Future<void> _issueCode() async {
    if (_c.loginCodeExpiresAt != null &&
        !await _confirm(context.t('detail.replaceTitle'), context.t('detail.replaceBody'), context.t('detail.generateBtn'))) {
      return;
    }
    try {
      final res = await context.read<ApiClient>().post('/v1/admin/clients/${_c.id}/login-code', {}) as Map<String, dynamic>;
      if (!mounted) return;
      await showLoginCodeDialog(
        context,
        clientName: _c.displayName,
        code: res['loginCode'] as String,
        expiresAt: DateTime.parse(res['loginCodeExpiresAt'] as String).toLocal(),
      );
      _changed = true;
      await _reload();
    } catch (e) {
      if (mounted) _toast(describeError(e));
    }
  }

  Future<void> _signOutEverywhere() async {
    if (!await _confirm(context.t('detail.signOutTitle'), context.t('detail.signOutBody', {'name': _c.displayName}), context.t('common.signOut'))) {
      return;
    }
    try {
      await context.read<ApiClient>().post('/v1/admin/clients/${_c.id}/sign-out', {});
      if (mounted) _toast(context.t('detail.signedOut', {'name': _c.displayName}));
    } catch (e) {
      if (mounted) _toast(describeError(e));
    }
  }

  Future<void> _extend(String plan) async {
    final months = plan == 'pro' ? 3 : 1;
    if (!await _confirm(context.t('plan.extendTitle'), context.t('plan.extendBody', {'name': _c.displayName, 'plan': context.t('plan.$plan'), 'm': months}),
        context.t('plan.extendBtn'))) {
      return;
    }
    try {
      final j = await context.read<ApiClient>().post('/v1/admin/clients/${_c.id}/extend', {'plan': plan}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _c = ClientAccount.fromJson(j));
      _changed = true;
      _toast(context.t('plan.extended', {'date': _c.accessUntil == null ? '—' : formatDateTime(_c.accessUntil!)}));
    } catch (e) {
      if (mounted) _toast(describeError(e));
    }
  }

  Future<void> _toggleActive() async {
    final deactivating = _c.isActive;
    if (!await _confirm(
      context.t(deactivating ? 'detail.deactivateTitle' : 'detail.reactivateTitle'),
      context.t(deactivating ? 'detail.deactivateBody' : 'detail.reactivateBody', {'name': _c.displayName}),
      context.t(deactivating ? 'detail.deactivate' : 'detail.reactivate'),
    )) {
      return;
    }
    try {
      await context.read<ApiClient>().patch('/v1/admin/clients/${_c.id}', {'isActive': !_c.isActive});
      _changed = true;
      await _reload();
    } catch (e) {
      if (mounted) _toast(describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = _c.loginCodeExpiresAt;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_c.displayName)),
        body: ListView(
          children: [
            if (!_c.isActive)
              MaterialBanner(
                content: Text(context.t('detail.inactiveBanner')),
                actions: const [SizedBox.shrink()],
              ),
            ListTile(
              title: Text(context.t('form.email')),
              subtitle: SelectableText(_c.email ?? '—'),
              trailing: _c.email == null
                  ? null
                  : IconButton(
                      tooltip: context.t('common.copy'),
                      icon: const Icon(Icons.copy),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _c.email!));
                        if (mounted) _toast(context.t('admin.emailCopied'));
                      },
                    ),
            ),
            // Plan: end date, days left (red when ended) and the two renew buttons.
            ListTile(
              title: Text(context.t('plan.title')),
              subtitle: Text(
                _c.accessUntil == null
                    ? context.t('plan.none')
                    : '${_c.plan == null ? '' : '${context.t('plan.${_c.plan}')} · '}'
                        '${context.t(_c.expired ? 'plan.endedOn' : 'plan.until', {'date': formatDateTime(_c.accessUntil!), 'd': _c.daysLeft})}',
                style: TextStyle(color: _c.expired ? Colors.red.shade700 : null, fontWeight: _c.expired ? FontWeight.bold : null),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(children: [
                Expanded(child: OutlinedButton(onPressed: () => _extend('basic'), child: Text(context.t('plan.addBasic')))),
                const SizedBox(width: 8),
                Expanded(child: FilledButton.tonal(onPressed: () => _extend('pro'), child: Text(context.t('plan.addPro')))),
              ]),
            ),
            ListTile(
              title: Text(context.t('detail.loginCode')),
              subtitle: Text(code == null ? context.t('detail.noneWaiting') : context.t('detail.waiting', {'time': formatDateTime(code)})),
            ),
            ListTile(
              title: Text(context.t('detail.lastSignIn')),
              subtitle: Text(_c.lastLoginAt == null ? context.t('detail.never') : formatDateTime(_c.lastLoginAt!)),
            ),
            const Divider(),
            if (_c.isActive)
              ListTile(leading: const Icon(Icons.pin), title: Text(context.t('detail.generate')), onTap: _issueCode),
            ListTile(leading: const Icon(Icons.edit), title: Text(context.t('detail.editNameEmail')), onTap: _edit),
            if (_c.isActive)
              ListTile(leading: const Icon(Icons.logout), title: Text(context.t('detail.signOutAll')), onTap: _signOutEverywhere),
            ListTile(
              leading: Icon(_c.isActive ? Icons.block : Icons.check_circle),
              title: Text(context.t(_c.isActive ? 'detail.deactivate' : 'detail.reactivate')),
              onTap: _toggleActive,
            ),
          ],
        ),
      ),
    );
  }
}
