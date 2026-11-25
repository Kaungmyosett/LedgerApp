import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../auth/auth_state.dart';
import '../i18n/lang.dart';
import '../ledger/draw_period.dart';
import '../ledger/ledger_store.dart';
import '../models/client_account.dart';
import '../util/format.dart';
import '../util/server_url.dart';
import 'ledger/bets_tab.dart';
import 'ledger/common.dart';
import 'ledger/cover_tab.dart';
import 'ledger/debt_tab.dart';
import 'ledger/dialogs.dart';
import 'ledger/history_tab.dart';
import 'ledger/home_tab.dart';
import 'ledger/numbers_tab.dart';
import 'ledger/users_tab.dart';

/// Client home: the whole ledger. Works offline; changes are saved on the phone and synced to the server.
class ClientHomeScreen extends StatefulWidget {
  const ClientHomeScreen({super.key});

  @override
  State<ClientHomeScreen> createState() => _ClientHomeScreenState();
}

class _ClientHomeScreenState extends State<ClientHomeScreen> with WidgetsBindingObserver {
  LedgerStore? _store;
  String? _initError;
  ClientAccount? _me; // plan end date for the banner; loaded in the background, offline is fine
  late DrawPeriod _drawPeriod;
  Timer? _periodTimer;

  @override
  void initState() {
    super.initState();
    _drawPeriod = drawPeriodAt(DateTime.now());
    _refreshDrawPeriod();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  Future<void> _open() async {
    setState(() => _initError = null);
    try {
      final api = context.read<ApiClient>();
      final fallbackOwner = context.read<AuthState>().displayName;
      final owner = (await api.store.owner.timeout(const Duration(seconds: 8))) ?? fallbackOwner;
      final dir = await getApplicationSupportDirectory();
      final store = LedgerStore(api: api, file: File('${dir.path}/ledger_data.json'), owner: owner);
      await store.start().timeout(const Duration(seconds: 15));
      if (!mounted) return store.dispose();
      setState(() => _store = store);
      _loadMe();
    } catch (e, st) {
      debugPrint('Ledger open failed: $e\n$st');
      if (mounted) setState(() => _initError = e.toString());
    }
  }

  Future<void> _loadMe() async {
    try {
      final j = await context.read<ApiClient>().get('/v1/client/me') as Map<String, dynamic>;
      if (mounted) setState(() => _me = ClientAccount.fromJson(j));
    } catch (_) {
      // Offline or server down: no banner, the ledger still works.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshDrawPeriod();
      _store?.sync();
      _loadMe();
    }
  }

  void _refreshDrawPeriod() {
    final now = DateTime.now();
    final period = drawPeriodAt(now);
    if (period != _drawPeriod) setState(() => _drawPeriod = period);
    _periodTimer?.cancel();
    _periodTimer = Timer(nextDrawPeriod(now).difference(now), _refreshDrawPeriod);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _periodTimer?.cancel();
    _store?.dispose();
    super.dispose();
  }

  Widget _planBanner(BuildContext context, LedgerStore s) {
    final lock = s.lockReason();
    if (lock == 'OFFLINE_TOO_LONG' || lock == 'CLOCK_CHANGED') return _lockBanner(context, context.t('lock.$lock'));
    return _planBannerFor(context, ended: lock == 'PLAN_EXPIRED' || s.lastErrorCode == 'PLAN_EXPIRED' || (_me?.expired ?? false), me: _me);
  }

  Future<void> _signOut() async {
    final s = _store!;
    if (s.hasUnsynced) {
      final ok = await confirmDialog(context, context.t('sync.signOutTitle'), context.t('sync.signOutBody', {'n': s.pending}), context.t('common.signOut'));
      if (!ok || !mounted) return;
    }
    final clean = !s.hasUnsynced && s.failed.isEmpty;
    final auth = context.read<AuthState>();
    if (clean) await s.wipe();
    await auth.logout();
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('2D Ledger')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SelectableText(_initError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _open, child: Text(context.t('common.retry'))),
              TextButton(onPressed: () => context.read<AuthState>().logout(), child: Text(context.t('common.signOut'))),
            ]),
          ),
        ),
      );
    }
    final store = _store;
    if (store == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<LedgerStore>.value(value: store),
        Provider<DrawPeriod>.value(value: _drawPeriod),
      ],
      child: DefaultTabController(
        length: 7,
        child: Consumer<LedgerStore>(builder: (context, s, _) {
          return Scaffold(
            appBar: AppBar(
              title: Text(context.read<AuthState>().displayName.isEmpty ? context.t('app.title') : context.read<AuthState>().displayName),
              actions: [
                _SyncButton(store: s),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    switch (v) {
                      case 'draw':
                        showDrawResults(context);
                      case 'blocked':
                        showBlockedNumbers(context);
                      case 'finalize':
                        showFinalize(context);
                      case 'lang':
                        context.lang.toggle();
                      case 'server':
                        showServerDialog(context).then((_) => s.sync());
                      case 'out':
                        _signOut();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'draw', child: Text(context.t('menu.draws'))),
                    PopupMenuItem(value: 'blocked', child: Text(context.t('menu.blocked'))),
                    PopupMenuItem(value: 'finalize', child: Text(context.t('menu.finalize'))),
                    const PopupMenuDivider(),
                    PopupMenuItem(value: 'lang', child: Text(context.t('common.language'))),
                    PopupMenuItem(value: 'server', child: Text(context.t('server.title'))),
                    PopupMenuItem(value: 'out', child: Text(context.t('common.signOut'))),
                  ],
                ),
              ],
              bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
                Tab(text: context.t('tab.home')), Tab(text: context.t('tab.users')), Tab(text: context.t('tab.bets')), Tab(text: context.t('tab.numbers')),
                Tab(text: context.t('tab.cover')), Tab(text: context.t('tab.history')), Tab(text: context.t('tab.debt')),
              ]),
            ),
            body: Column(children: [
              _planBanner(context, s),
              if (s.failed.isNotEmpty) _FailedBanner(store: s),
              Expanded(child: TabBarView(children: [
                HomeTab(openDebt: () {
                  final tabs = DefaultTabController.of(context);
                  tabs.animateTo(tabs.length - 1);
                }),
                const UsersTab(), const BetsTab(), const NumbersTab(), const CoverTab(),
                const HistoryTab(), const DebtTab(),
              ])),
            ]),
          );
        }),
      ),
    );
  }
}

Widget _lockBanner(BuildContext context, String text) => Material(
      color: Colors.red.shade100,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(children: [
          const Icon(Icons.lock_clock, color: Colors.black87),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w600))),
        ]),
      ),
    );

/// Plan ended (server refused) -> red. Ends within 7 days -> orange. Otherwise nothing.
Widget _planBannerFor(BuildContext context, {required bool ended, ClientAccount? me}) {
  final String text;
  final Color bg;
  if (ended) {
    text = context.t('plan.clientEnded');
    bg = Colors.red.shade100;
  } else if (me != null && me.accessUntil != null && me.daysLeft <= 7) {
    text = context.t('plan.clientEndsSoon', {'d': me.daysLeft, 'date': formatDateTime(me.accessUntil!)});
    bg = Colors.orange.shade100;
  } else {
    return const SizedBox.shrink();
  }
  return Material(
    color: bg,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(children: [
        const Icon(Icons.event_busy, color: Colors.black87),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w600))),
      ]),
    ),
  );
}

class _SyncButton extends StatelessWidget {
  const _SyncButton({required this.store});
  final LedgerStore store;

  @override
  Widget build(BuildContext context) {
    final offline = store.lastError != null;
    final msg = offline
        ? (store.lastError!.startsWith('Offline') ? context.t('sync.offline') : store.lastError!)
        : (store.hasUnsynced ? context.t('sync.waiting', {'n': store.pending}) : context.t('sync.synced'));
    final icon = store.syncing
        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(offline ? Icons.cloud_off : (store.hasUnsynced ? Icons.cloud_upload : Icons.cloud_done));
    return IconButton(
      tooltip: msg,
      icon: Badge(isLabelVisible: store.hasUnsynced, label: Text('${store.pending}'), child: icon),
      onPressed: () {
        store.sync();
        toast(context, offline || store.hasUnsynced ? msg : context.t('sync.syncing'));
      },
    );
  }
}

class _FailedBanner extends StatelessWidget {
  const _FailedBanner({required this.store});
  final LedgerStore store;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(children: [
          Icon(Icons.error_outline, color: cs.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(child: Text(context.t('failed.banner', {'n': store.failed.length}), style: TextStyle(color: cs.onErrorContainer))),
          TextButton(onPressed: () => _show(context), child: Text(context.t('failed.view'))),
        ]),
      ),
    );
  }

  void _show(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('failed.title')),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final f in store.failed) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('• ${ctx.t('op.${f.what}')}: ${trRule(ctx, f.code, f.message)}')),
            const SizedBox(height: 8),
            Text(ctx.t('failed.note')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () { store.dismissAllFailed(); Navigator.pop(ctx); }, child: Text(ctx.t('failed.dismiss'))),
        ],
      ),
    );
  }
}
