import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, [this.details = const []]);
  final int status;
  final String code;
  final String message;
  final List<String> details;
  @override
  String toString() => message;
}

class NetworkException implements Exception {
  NetworkException([this.code = 'CONNECTION_FAILED']);
  final String code;

  @override
  String toString() => 'Cannot reach the server. Check your internet connection.';
}

class ApiDiagnostic {
  const ApiDiagnostic({
    required this.at, required this.category, required this.source,
    required this.operation, required this.code, this.status, this.clientId, this.clientName,
  });

  final DateTime at;
  final String category, source, operation, code;
  final int? status;
  final String? clientId, clientName;

  factory ApiDiagnostic.fromJson(Map<String, dynamic> json) => ApiDiagnostic(
    at: DateTime.parse(json['at'] as String),
    category: json['category'] as String, source: json['source'] as String,
    operation: json['operation'] as String, code: json['code'] as String,
    status: json['status'] as int?, clientId: json['clientId'] as String?,
    clientName: json['clientName'] as String?,
  );

  Map<String, dynamic> toReport() => {
    'at': at.toUtc().toIso8601String(), 'category': category, 'operation': operation,
    'code': code, if (status != null) 'status': status,
  };
}

/// Tokens live in the OS keychain / keystore, not in plain preferences.
class SessionStore {
  final _s = const FlutterSecureStorage();
  Future<String?> get accessToken => _s.read(key: 'access');
  Future<String?> get refreshToken => _s.read(key: 'refresh');
  Future<String?> get role => _s.read(key: 'role');
  Future<String?> get name => _s.read(key: 'name');
  /// Login identifier (client e-mail). The local ledger copy is only reused for the same owner.
  Future<String?> get owner => _s.read(key: 'owner');

  Future<void> saveTokens(String access, String refresh) async {
    await _s.write(key: 'access', value: access);
    await _s.write(key: 'refresh', value: refresh);
  }

  Future<void> saveProfile(String role, String name, {String? owner}) async {
    await _s.write(key: 'role', value: role);
    await _s.write(key: 'name', value: name);
    if (owner != null) await _s.write(key: 'owner', value: owner);
  }

  /// Removes the session only (the language setting and other app settings stay).
  Future<void> clear() async {
    for (final k in const ['access', 'refresh', 'role', 'name', 'owner']) {
      await _s.delete(key: k);
    }
  }
}

class ApiClient {
  ApiClient({required String baseUrl, SessionStore? store, http.Client? httpClient})
      : _baseUrl = baseUrl, store = store ?? SessionStore(),
        _http = httpClient ?? http.Client();

  /// Can change at run time (Server setting), so it is not final.
  String _baseUrl;
  String get baseUrl => _baseUrl;
  set baseUrl(String value) {
    if (value == _baseUrl) return;
    _baseUrl = value;
    _diagnosticGeneration++;
    _pendingDiagnostics.clear();
    _localDiagnostics.clear();
  }

  final _localDiagnostics = <ApiDiagnostic>[];
  final _pendingDiagnostics = <ApiDiagnostic>[];
  List<ApiDiagnostic> get localDiagnostics => List.unmodifiable(_localDiagnostics);
  String? _diagnosticRole;
  int _diagnosticGeneration = 0;
  bool _reporting = false;
  DateTime? _lastReportAttempt;

  void setDiagnosticRole(String? role) {
    _diagnosticRole = role;
    _diagnosticGeneration++;
    _pendingDiagnostics.clear();
    _lastReportAttempt = null;
  }

  static const _clientDiagnosticPaths = {
    '/v1/client/me', '/v1/client/ledger/sync', '/v1/client/ledger/snapshot', '/v1/auth/refresh',
  };

  void _record(String path, String category, String code, int generation, {int? status}) {
    if (generation != _diagnosticGeneration || path == '/v1/client/diagnostics') return;
    final entry = ApiDiagnostic(
      at: DateTime.now().toUtc(), category: category, source: _diagnosticRole ?? (path == '/v1/auth/admin/login' ? 'admin' : 'client'),
      operation: path.replaceAll(RegExp(r'[0-9a-fA-F-]{36}'), ':id'),
      code: code, status: status,
    );
    _localDiagnostics.add(entry);
    if (_localDiagnostics.length > 100) _localDiagnostics.removeAt(0);
    if (_diagnosticRole != 'client' || !_clientDiagnosticPaths.contains(path)) return;
    final previous = _pendingDiagnostics.lastOrNull;
    if (previous?.operation == entry.operation &&
        previous?.code == code && previous?.status == status &&
        entry.at.difference(previous!.at) < const Duration(minutes: 1)) return;
    _pendingDiagnostics.add(entry);
    if (_pendingDiagnostics.length > 20) _pendingDiagnostics.removeAt(0);
  }

  Future<void> _reportDiagnostics(int generation) async {
    final now = DateTime.now();
    if (generation != _diagnosticGeneration || _diagnosticRole != 'client' ||
        _reporting || _pendingDiagnostics.isEmpty ||
        (_lastReportAttempt != null && now.difference(_lastReportAttempt!) < const Duration(minutes: 1))) return;
    _reporting = true;
    _lastReportAttempt = now;
    final batch = [..._pendingDiagnostics];
    try {
      final token = await store.accessToken;
      if (token == null || generation != _diagnosticGeneration) return;
      final response = await _send('POST', '/v1/client/diagnostics',
          body: {'events': batch.map((entry) => entry.toReport()).toList()},
          auth: false, bearerToken: token);
      if (generation == _diagnosticGeneration && response.statusCode == 204) {
        _pendingDiagnostics.removeWhere(batch.contains);
      }
    } catch (_) {
      // A retry on a later successful request can deliver the buffered events.
    } finally {
      _reporting = false;
    }
  }
  final SessionStore store;
  final http.Client _http;

  /// Called when the refresh token is rejected: the user must log in again.
  void Function()? onSessionExpired;
  Future<bool>? _refreshing;

  Future<dynamic> get(String path, {Map<String, String>? query}) => request('GET', path, query: query);
  Future<dynamic> post(String path, Map<String, dynamic> body, {bool auth = true}) =>
      request('POST', path, body: body, auth: auth);
  Future<dynamic> patch(String path, Map<String, dynamic> body) => request('PATCH', path, body: body);

  Future<void> saveTokens(Map<String, dynamic> session) =>
      store.saveTokens(session['accessToken'] as String, session['refreshToken'] as String);

  Future<dynamic> request(String method, String path,
      {Map<String, dynamic>? body, Map<String, String>? query, bool auth = true}) async {
    final generation = _diagnosticGeneration;
    try {
      var res = await _send(method, path, body: body, query: query, auth: auth);
      if (auth && res.statusCode == 401 && _code(res) == 'UNAUTHENTICATED') {
        if (await _refresh()) {
          res = await _send(method, path, body: body, query: query, auth: auth);
        }
        if (res.statusCode == 401 && _code(res) == 'UNAUTHENTICATED') await _expire();
      }
      final value = _decode(res);
      if (auth) unawaited(_reportDiagnostics(generation));
      return value;
    } on NetworkException catch (error) {
      _record(path, 'network', error.code, generation);
      rethrow;
    } on ApiException catch (error) {
      if (error.status >= 400 && error.status <= 599) {
        _record(path, _diagnosticRole == 'admin' ? 'server' : 'client', 'HTTP_ERROR',
            generation, status: error.status);
      }
      rethrow;
    } on FormatException {
      _record(path, 'client', 'INVALID_RESPONSE', generation);
      rethrow;
    }
  }

  Future<http.Response> _send(String method, String path,
      {Map<String, dynamic>? body, Map<String, String>? query, required bool auth, String? bearerToken}) async {
    var uri = Uri.parse('$baseUrl$path');
    if (query != null && query.isNotEmpty) uri = uri.replace(queryParameters: query);
    final req = http.Request(method, uri)..headers['content-type'] = 'application/json';
    final token = bearerToken ?? (auth ? await store.accessToken : null);
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) req.body = jsonEncode(body);
    try {
      final streamed = await _http.send(req).timeout(const Duration(seconds: 20));
      return await http.Response.fromStream(streamed).timeout(const Duration(seconds: 20));
    } on SocketException {
      throw NetworkException();
    } on TimeoutException {
      throw NetworkException('TIMEOUT');
    } on TlsException {
      throw NetworkException();
    } on http.ClientException {
      throw NetworkException();
    }
  }

  // One refresh at a time: refresh tokens rotate, so parallel refreshes would invalidate each other.
  Future<bool> _refresh() => _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<bool> _doRefresh() async {
    final refresh = await store.refreshToken;
    if (refresh == null) return false; // request() then expires the session
    final res = await _send('POST', '/v1/auth/refresh', body: {'refreshToken': refresh}, auth: false);
    if (res.statusCode == 200) {
      await saveTokens(jsonDecode(res.body) as Map<String, dynamic>);
      return true;
    }
    // 400/401/403/404: the refresh token is unknown (e.g. the database was reset) -> sign in again.
    // Network problems throw NetworkException above and keep the session for later.
    if (res.statusCode >= 400 && res.statusCode < 500 && res.statusCode != 429) await _expire();
    return false;
  }

  bool _expiring = false;
  Future<void> _expire() async {
    if (_expiring) return;
    _expiring = true;
    try {
      await store.clear();
    } catch (_) {
    } finally {
      _expiring = false;
    }
    setDiagnosticRole(null);
    onSessionExpired?.call();
  }

  String? _code(http.Response res) {
    try {
      return (jsonDecode(res.body) as Map<String, dynamic>)['error'] as String?;
    } catch (_) {
      return null;
    }
  }

  dynamic _decode(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return res.body.isEmpty ? null : jsonDecode(res.body);
    }
    var code = 'HTTP_${res.statusCode}';
    var message = 'Request failed (${res.statusCode}).';
    var details = <String>[];
    try {
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      code = (j['error'] as String?) ?? code;
      message = (j['message'] as String?) ?? message;
      if (code == 'VALIDATION_ERROR' && j['details'] is List) {
        details = (j['details'] as List)
            .map((d) => '${(d as Map)['path']}: ${d['message']}'.replaceFirst(RegExp(r'^: '), ''))
            .toList();
      }
    } catch (_) {}
    throw ApiException(res.statusCode, code, message, details);
  }
}
