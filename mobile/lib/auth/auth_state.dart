import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../config.dart';

enum AuthStatus { loading, signedOut, admin, client }

class AuthState extends ChangeNotifier {
  AuthState(this.api) {
    api.onSessionExpired = () {
      status = AuthStatus.signedOut;
      notifyListeners();
    };
  }

  final ApiClient api;
  AuthStatus status = AuthStatus.loading;
  String displayName = '';

  /// Restore a saved session without needing the network, so the app opens offline.
  /// Never leaves the app on the loading screen: if the saved session can't be read, the user just signs in again.
  Future<void> init() async {
    try {
      final role = await api.store.role.timeout(const Duration(seconds: 8));
      final refresh = await api.store.refreshToken.timeout(const Duration(seconds: 8));
      displayName = await api.store.name.timeout(const Duration(seconds: 8)) ?? '';
      status = (refresh == null || role == null || !roleAllowed(role))
          ? AuthStatus.signedOut
          : role == 'admin'
              ? AuthStatus.admin
              : AuthStatus.client;
    } catch (e) {
      debugPrint('AuthState.init failed: $e');
      try {
        await api.store.clear().timeout(const Duration(seconds: 5));
      } catch (_) {}
      status = AuthStatus.signedOut;
    }
    notifyListeners();
  }

  /// Admin: [identifier] is the phone number and [secret] the password.
  /// Client: [identifier] is the email and [secret] the 6-digit code the Admin issued.
  Future<void> login(String role, String identifier, String secret) async {
    // A client build has no Admin login at all (and an admin build no Client login).
    if (!roleAllowed(role)) throw StateError('This app does not allow $role login.');
    final data = (role == 'admin'
        ? await api.post('/v1/auth/admin/login', {'phone': identifier, 'password': secret}, auth: false)
        : await api.post('/v1/auth/client/login', {'email': identifier, 'code': secret}, auth: false))
        as Map<String, dynamic>;
    await api.saveTokens(data);
    displayName = (data['account'] as Map<String, dynamic>)['displayName'] as String;
    await api.store.saveProfile(role, displayName, owner: identifier.trim().toLowerCase());
    status = role == 'admin' ? AuthStatus.admin : AuthStatus.client;
    notifyListeners();
  }

  /// Admin only: clients have no password.
  Future<void> changePassword(String current, String next) async {
    final data = await api.post('/v1/auth/admin/change-password', {'currentPassword': current, 'newPassword': next})
        as Map<String, dynamic>;
    await api.saveTokens(data); // other devices were signed out; this one gets a fresh session
  }

  /// Always ends on the login screen, even offline or if the phone storage misbehaves.
  Future<void> logout() async {
    String? refresh;
    try {
      refresh = await api.store.refreshToken.timeout(const Duration(seconds: 5));
    } catch (_) {}
    // Leave the signed-in screens first so they stop calling the server.
    displayName = '';
    status = AuthStatus.signedOut;
    notifyListeners();
    // Clear before talking to the server, so a quick new login can't be wiped afterwards.
    try {
      await api.store.clear();
    } catch (_) {}
    if (refresh != null) {
      try {
        await api.post('/v1/auth/logout', {'refreshToken': refresh}, auth: false);
      } catch (_) {
        // Offline logout still clears this device.
      }
    }
  }
}
