import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/api_client.dart';
import 'auth/auth_state.dart';
import 'config.dart';
import 'i18n/lang.dart';
import 'screens/admin_home_screen.dart';
import 'screens/client_home_screen.dart';
import 'screens/login_screen.dart';
import 'util/server_url.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A server address saved in the app (Server setting) wins over the built-in one.
  final api = ApiClient(baseUrl: (await loadServerUrl()) ?? apiBaseUrl);
  final auth = AuthState(api)..init();
  final lang = Lang()..load();
  runApp(MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      ChangeNotifierProvider<AuthState>.value(value: auth),
      ChangeNotifierProvider<Lang>.value(value: lang),
    ],
    child: const LedgerApp(),
  ));
}

class LedgerApp extends StatefulWidget {
  const LedgerApp({super.key});

  @override
  State<LedgerApp> createState() => _LedgerAppState();
}

class _LedgerAppState extends State<LedgerApp> {
  final _navKey = GlobalKey<NavigatorState>();
  late final AuthState _auth;

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthState>();
    _auth.addListener(_onAuthChanged);
  }

  // When the session ends, drop any screens pushed on top of the home screen.
  void _onAuthChanged() {
    if (_auth.status == AuthStatus.signedOut) {
      _navKey.currentState?.popUntil((r) => r.isFirst);
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = context.watch<AuthState>().status;
    // Changing the language rebuilds the whole app with the new texts (the ledger reloads from the phone).
    final langCode = context.watch<Lang>().code;
    return MaterialApp(
      key: ValueKey(langCode),
      title: '2D Ledger',
      navigatorKey: _navKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: switch (status) {
        AuthStatus.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
        AuthStatus.signedOut => const LoginScreen(),
        AuthStatus.admin => const AdminHomeScreen(),
        AuthStatus.client => const ClientHomeScreen(),
      },
    );
  }
}
