import 'dart:io' show Platform;

import 'package:flutter/services.dart' show appFlavor;

/// API address. Override at run time:
///   flutter run --dart-define=API_URL=http://192.168.1.20:3000
/// Defaults: Android emulator -> 10.0.2.2 (the host Mac); iOS simulator -> localhost.
String get apiBaseUrl {
  const fromEnv = String.fromEnvironment('API_URL');
  if (fromEnv.isNotEmpty) return fromEnv;
  return Platform.isAndroid ? 'http://10.0.2.2:3000' : 'http://localhost:3000';
}

/// Which logins this build offers: 'client', 'admin' or 'both'.
///  * Production: comes from the Android/iOS flavor (`flutter build apk --flavor client` -> 'client'),
///    so the client app can never be built with the Admin login by mistake.
///  * `--dart-define=APP_MODE=...` overrides it (handy before flavors are set up).
///  * Plain `flutter run` without a flavor: 'both' (development).
String get appMode {
  const fromEnv = String.fromEnvironment('APP_MODE');
  if (fromEnv == 'client' || fromEnv == 'admin' || fromEnv == 'both') return fromEnv;
  final f = appFlavor;
  if (f == 'client' || f == 'admin') return f!;
  return 'both';
}

bool roleAllowed(String role) => appMode == 'both' || appMode == role;
