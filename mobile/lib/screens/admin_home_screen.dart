import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../auth/auth_state.dart';
import '../i18n/lang.dart';
import '../models/client_account.dart';
import '../util/format.dart';
import '../util/server_url.dart';
import 'admin_logs_screen.dart';
import 'change_password_dialog.dart';
import 'client_detail_screen.dart';
import 'client_form_screen.dart';

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  final _search = TextEditingController();
  List<ClientAccount> _clients = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final q = _search.text.trim();
      final data = await context.read<ApiClient>().get('/v1/admin/clients',
          query: {'limit': '200', if (q.isNotEmpty) 'q': q}) as Map<String, dynamic>;
      _clients = (data['clients'] as List).map((j) => ClientAccount.fromJson(j as Map<String, dynamic>)).toList();
    } catch (e) {
      _error = describeError(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(Widget screen) async {
    final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => screen));
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t('admin.clients', {'name': auth.displayName})),
        actions: [
          IconButton(
            tooltip: context.t('logs.title'),
            icon: const Icon(Icons.monitor_heart_outlined),
            onPressed: () => Navigator.push<void>(context, MaterialPageRoute(builder: (_) => const AdminLogsScreen())),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'pw') showChangePasswordDialog(context);
              if (v == 'out') context.read<AuthState>().logout();
              if (v == 'lang') context.lang.toggle();
              if (v == 'server') showServerDialog(context);
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'pw', child: Text(context.t('admin.changePw'))),
              PopupMenuItem(value: 'lang', child: Text(context.t('common.language'))),
              PopupMenuItem(value: 'server', child: Text(context.t('server.title'))),
              PopupMenuItem(value: 'out', child: Text(context.t('common.signOut'))),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(const ClientFormScreen()),
        icon: const Icon(Icons.person_add),
        label: Text(context.t('admin.newClient')),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                hintText: context.t('admin.search'),
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _search.clear();
                    _load();
                  },
                ),
              ),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: Text(context.t('common.retry'))),
          ]),
        ),
      );
    }
    if (_clients.isEmpty) return Center(child: Text(context.t('admin.empty')));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: _clients.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final c = _clients[i];
          return ListTile(
            leading: CircleAvatar(child: Text(c.displayName.characters.first.toUpperCase())),
            title: Text(c.displayName),
            subtitle: Text.rich(TextSpan(children: [
              TextSpan(text: [
                c.email ?? '—',
                if (c.isActive && c.loginCodeExpiresAt != null) context.t('admin.codeWaiting') else if (c.isActive && c.lastLoginAt == null) context.t('admin.neverSignedIn'),
              ].join(' · ')),
              // Plan end: red when ended, orange in the last 7 days.
              TextSpan(
                text: '\n${c.plan == null ? '' : '${context.t('plan.${c.plan}')} · '}'
                    '${c.expired ? context.t('plan.ended') : context.t('plan.daysLeft', {'d': c.daysLeft})}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: c.expired ? Colors.red.shade700 : (c.daysLeft <= 7 ? Colors.orange.shade800 : Colors.green.shade700),
                ),
              ),
            ])),
            isThreeLine: true,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (c.email != null)
                IconButton(
                  tooltip: context.t('common.copy'),
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: c.email!));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(SnackBar(content: Text(context.t('admin.emailCopied'))));
                    }
                  },
                ),
              if (c.isActive) const Icon(Icons.chevron_right) else Chip(label: Text(context.t('admin.inactive'))),
            ]),
            // Inactive clients stay tappable so the Admin can reactivate them.
            onTap: () => _open(ClientDetailScreen(client: c)),
          );
        },
      ),
    );
  }
}
