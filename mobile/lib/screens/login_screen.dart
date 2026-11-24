import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../auth/auth_state.dart';
import '../config.dart';
import '../util/server_url.dart';
import '../i18n/lang.dart';
import '../util/format.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _pw = TextEditingController();
  // A client-only build starts (and stays) on Client; an admin-only build on Admin.
  String _role = appMode == 'admin' ? 'admin' : 'client';
  bool _hide = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AuthState>().login(_role, _id.text.trim(), _pw.text);
    } catch (e) {
      if (mounted) {
        setState(() => _error = (e is ApiException && e.code == 'PLAN_EXPIRED') ? context.t('err.PLAN_EXPIRED') : describeError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = _role == 'admin';
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      IconButton(
                        tooltip: context.t('server.title'),
                        icon: const Icon(Icons.dns_outlined),
                        onPressed: () => showServerDialog(context),
                      ),
                      const Spacer(),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [ButtonSegment(value: 'my', label: Text('မြန်မာ')), ButtonSegment(value: 'en', label: Text('English'))],
                        selected: {context.lang.code},
                        onSelectionChanged: (s) => context.lang.set(s.first),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Text(context.t('app.title'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 24),
                    if (appMode == 'both')
                    SegmentedButton<String>(
                      segments: [
                        ButtonSegment(value: 'client', label: Text(context.t('login.client'))),
                        ButtonSegment(value: 'admin', label: Text(context.t('login.admin'))),
                      ],
                      selected: {_role},
                      onSelectionChanged: _busy
                          ? null
                          : (s) => setState(() {
                                _role = s.first;
                                _pw.clear();
                                _error = null;
                              }),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _id,
                      keyboardType: isAdmin ? TextInputType.phone : TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: context.t(isAdmin ? 'login.phone' : 'login.email'),
                        border: const OutlineInputBorder(),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty) ? context.t('common.required') : null,
                    ),
                    const SizedBox(height: 12),
                    if (isAdmin)
                      TextFormField(
                        controller: _pw,
                        obscureText: _hide,
                        decoration: InputDecoration(
                          labelText: context.t('login.password'),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                            onPressed: () => setState(() => _hide = !_hide),
                          ),
                        ),
                        validator: (v) => (v == null || v.isEmpty) ? context.t('common.required') : null,
                        onFieldSubmitted: (_) => _submit(),
                      )
                    else
                      TextFormField(
                        controller: _pw,
                        keyboardType: TextInputType.number,
                        // digits only, so a pasted "123 456" becomes 123456 and the counter shows 0/6
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        maxLength: 6,
                        decoration: InputDecoration(
                          labelText: context.t('login.code'),
                          helperText: context.t('login.codeHelp'),
                          border: const OutlineInputBorder(),
                        ),
                        validator: (v) =>
                            RegExp(r'^\d{6}$').hasMatch((v ?? '').replaceAll(RegExp(r'[\s-]'), '')) ? null : context.t('login.codeInvalid'),
                        onFieldSubmitted: (_) => _submit(),
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(context.t('login.signIn')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
