import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../i18n/lang.dart';
import '../util/format.dart';

class AdminLogsScreen extends StatefulWidget {
  const AdminLogsScreen({super.key});

  @override
  State<AdminLogsScreen> createState() => _AdminLogsScreenState();
}

class _AdminLogsScreenState extends State<AdminLogsScreen> {
  String _category = 'all';
  int _request = 0;
  String? _error;
  bool _loading = true;
  List<ApiDiagnostic> _events = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    final api = context.read<ApiClient>();
    final category = _category;
    setState(() {
      _loading = true;
      _error = null;
    });
    List<ApiDiagnostic> server = [];
    String? error;
    try {
      final response = await api.get('/v1/admin/diagnostics',
              query: {if (category != 'all') 'category': category})
          as Map<String, dynamic>;
      server = (response['events'] as List)
          .map((entry) => ApiDiagnostic.fromJson(entry as Map<String, dynamic>))
          .toList();
    } catch (e) {
      error = describeError(e);
    }
    if (!mounted || request != _request) return;
    setState(() {
      _events = [
        ...server,
        ...api.localDiagnostics
            .where((entry) => category == 'all' || entry.category == category),
      ]..sort((a, b) => b.at.compareTo(a.at));
      _error = error;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('logs.title')),
        actions: [
          IconButton(
              tooltip: t('common.retry'),
              onPressed: _load,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: DropdownButton<String>(
            value: _category,
            isExpanded: true,
            items: [
              for (final part in [
                'all',
                'server',
                'client',
                'login',
                'database',
                'network'
              ])
                DropdownMenuItem(value: part, child: Text(t('logs.$part'))),
            ],
            onChanged: (value) {
              if (value == null || value == _category) return;
              _category = value;
              _load();
            },
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(error,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Expanded(
          child: _events.isEmpty && !_loading
              ? Center(child: Text(t('logs.empty')))
              : ListView.builder(
                  itemCount: _events.length,
                  itemBuilder: (context, index) {
                    final event = _events[index];
                    return ListTile(
                      title: Text(
                          '${t('logs.${event.category}')} · ${event.code}'),
                      subtitle: Text([
                        '${formatDateTime(event.at)} · ${t('logs.source.${event.source}')}',
                        [
                          event.operation,
                          if (event.status != null) 'HTTP ${event.status}'
                        ].join(' · '),
                        if (event.clientId != null) event.clientName ?? event.clientId!,
                      ].join('\n')),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
