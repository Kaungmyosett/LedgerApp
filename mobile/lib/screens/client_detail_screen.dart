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
    if (!mounted) return;
    try {
      final updated = await context.read<ApiClient>().patch('/v1/admin/clients/${_c.id}', {'isActive': !deactivating}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _c = ClientAccount.fromJson(updated));
      _changed = true;
    } catch (e) {
      if (mounted) _toast(describeError(e));
    }
  }

  Future<DateTime?> _pickExpiry({
    required DateTime initial,
    required DateTime firstDate,
    required DateTime lastDate,
  }) async {
    final date = await showDatePicker(
      context: context, initialDate: initial, firstDate: firstDate, lastDate: lastDate,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null || !mounted) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _chooseTestExpiry() async {
    final now = DateTime.now();
    final initial = _c.testAccessUntil ?? now;
    final until = await _pickExpiry(
      initial: initial,
      firstDate: DateTime(initial.year < now.year ? initial.year : now.year - 5),
      lastDate: DateTime(initial.year > now.year ? initial.year + 1 : now.year + 10),
    );
    if (until != null && mounted) await _setTestExpiry(until);
  }

  DateTime? get _regularExpiry =>
      _c.regularAccessUntil ?? (_c.testAccessUntil == null ? _c.accessUntil : null);

  Future<void> _shorten() async {
    final regular = _regularExpiry;
    if (regular == null) return;
    final until = await _pickExpiry(
      initial: regular.subtract(const Duration(days: 1)),
      firstDate: DateTime(regular.year - 5),
      lastDate: DateUtils.dateOnly(regular),
    );
    if (until == null || !mounted) return;
    if (!until.isBefore(regular)) {
      _toast(context.t('plan.earlierRequired'));
      return;
    }

    final body = [
      context.t('plan.shortenBody', {
        'name': _c.displayName, 'from': formatDateTime(regular), 'to': formatDateTime(until),
      }),
      if (!until.isAfter(DateTime.now())) context.t('plan.shortenImmediate'),
      if (_c.testAccessUntil != null) context.t('plan.shortenTestOverride'),
    ].join('\n\n');
    if (!await _confirm(context.t('plan.shortenTitle'), body, context.t('plan.shorten')) || !mounted) return;

    try {
      final result = await context.read<ApiClient>().post(
        '/v1/admin/clients/${_c.id}/shorten', {'accessUntil': until.toUtc().toIso8601String()},
      ) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _c = ClientAccount.fromJson(result));
      _changed = true;
      _toast(context.t('plan.shortened', {'date': formatDateTime(_regularExpiry ?? until)}));
    } catch (e) {
      if (mounted) {
        _toast(e is ApiException && e.code == 'EXPIRY_NOT_EARLIER'
            ? context.t('plan.earlierRequired')
            : describeError(e));
      }
    }
  }

  Future<void> _setTestExpiry(DateTime? until) async {
    try {
      final result = await context.read<ApiClient>().patch(
        '/v1/admin/clients/${_c.id}/test-expiry',
        {'accessUntil': until?.toUtc().toIso8601String()},
      ) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _c = ClientAccount.fromJson(result));
      _changed = true;
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
            if (_regularExpiry != null)
              ListTile(
                leading: const Icon(Icons.event_busy_outlined),
                title: Text(context.t('plan.shorten')),
                onTap: _shorten,
              ),
            if (_c.testExpiryEnabled)
              ListTile(
                leading: const Icon(Icons.science_outlined),
                title: Text(context.t('plan.testExpiry')),
                subtitle: _c.testAccessUntil == null
                    ? null
                    : Text(context.t('plan.regularExpiry', {
                        'date': _c.regularAccessUntil == null ? '—' : formatDateTime(_c.regularAccessUntil!),
                      })),
                trailing: _c.testAccessUntil == null ? null : IconButton(
                  icon: const Icon(Icons.restore),
                  tooltip: context.t('plan.restoreExpiry'),
                  onPressed: () => _setTestExpiry(null),
                ),
                onTap: _chooseTestExpiry,
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
