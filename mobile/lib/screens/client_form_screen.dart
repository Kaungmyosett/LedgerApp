import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../i18n/lang.dart';
import '../models/client_account.dart';
import '../util/email.dart';
import '../util/format.dart';
import 'login_code_dialog.dart';

/// Create (existing == null) or edit a client account. Pops `true` when something was saved.
/// A client account is only a name + email: the ledger settings (commission, odd, ...)
/// live inside the client's own ledger. Clients have no password; creating one issues a login code.
class ClientFormScreen extends StatefulWidget {
  const ClientFormScreen({super.key, this.existing});
  final ClientAccount? existing;

  @override
  State<ClientFormScreen> createState() => _ClientFormScreenState();
}

class _ClientFormScreenState extends State<ClientFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.displayName);
  late final _email = TextEditingController(text: widget.existing?.email);
  bool _busy = false;
  String? _error;
  String _plan = 'basic'; // new clients only; existing clients are renewed from the client screen
  String? _emailError; // "already used" from the server

  bool get _editing => widget.existing != null;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _emailError = null);
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<ApiClient>();
    final email = normalizeEmail(_email.text)!;
    final body = <String, dynamic>{'displayName': _name.text.trim(), 'email': email, if (!_editing) 'plan': _plan};
    try {
      // Ask first so the Admin sees which client already has this email.
      if (!_editing || email != (widget.existing!.email ?? '').toLowerCase()) {
        final chk = await api.get('/v1/admin/clients/email-check', query: {
          'email': email,
          if (_editing) 'exceptId': widget.existing!.id,
        }) as Map<String, dynamic>;
        if (chk['available'] != true) {
          if (mounted) {
            setState(() => _emailError = chk['valid'] == false
                ? context.t('form.emailInvalid')
                : context.t('form.emailUsed', {'name': chk['usedBy'] ?? ''}));
          }
          return;
        }
      }
      if (_editing) {
        await api.patch('/v1/admin/clients/${widget.existing!.id}', body);
        if (mounted) Navigator.pop(context, true);
      } else {
        final res = await api.post('/v1/admin/clients', body) as Map<String, dynamic>;
        if (!mounted) return;
        await showLoginCodeDialog(
          context,
          clientName: _name.text.trim(),
          code: res['loginCode'] as String,
          expiresAt: DateTime.parse(res['loginCodeExpiresAt'] as String).toLocal(),
        );
        if (mounted) Navigator.pop(context, true);
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          if (e.code == 'CLIENT_ALREADY_EXISTS') {
            _emailError = context.t('form.emailUsed', {'name': RegExp(r'"(.*)"').firstMatch(e.message)?.group(1) ?? ''});
          } else {
            _error = describeError(e);
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.t(_editing ? 'form.editClient' : 'admin.newClient'))),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: context.t('form.name'), border: const OutlineInputBorder()),
                validator: (v) => (v == null || v.trim().isEmpty) ? context.t('common.required') : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: context.t('form.email'),
                  helperText: context.t('form.emailHelp'),
                  helperMaxLines: 3,
                  errorText: _emailError,
                  errorMaxLines: 3,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (_emailError != null) setState(() => _emailError = null);
                },
                validator: (v) {
                  final s = (v ?? '').trim();
                  if (s.isEmpty) return context.t('common.required');
                  return normalizeEmail(s) != null ? null : context.t('form.emailInvalid');
                },
              ),
              if (!_editing) ...[
                const SizedBox(height: 16),
                Text(context.t('plan.choose'), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'basic', label: Text(context.t('plan.basic'))),
                    ButtonSegment(value: 'pro', label: Text(context.t('plan.pro'))),
                  ],
                  selected: {_plan},
                  onSelectionChanged: (s) => setState(() => _plan = s.first),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(context.t('form.codeNote')),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(context.t(_editing ? 'form.saveChanges' : 'form.create')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
