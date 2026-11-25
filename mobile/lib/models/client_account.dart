class ClientAccount {
  const ClientAccount({
    required this.id,
    required this.displayName,
    required this.email,
    required this.isActive,
    this.loginCodeExpiresAt,
    this.lastLoginAt,
    this.plan,
    this.accessUntil,
    this.testExpiryEnabled = false,
    this.testAccessUntil,
    this.regularAccessUntil,
  });

  final String id;
  final String displayName;
  final String? email;
  final bool isActive;

  /// Set while the Admin has issued a login code that is still unused and unexpired.
  final DateTime? loginCodeExpiresAt;
  final DateTime? lastLoginAt;

  /// 'basic' (1 month) or 'pro' (3 months).
  final String? plan;

  /// When the client's access ends. After this the client cannot log in or sync (data is kept).
  final DateTime? accessUntil;
  final bool testExpiryEnabled;
  final DateTime? testAccessUntil, regularAccessUntil;

  bool get expired => accessUntil == null || !accessUntil!.isAfter(DateTime.now());

  /// Whole days left (0 when it ends today or has ended).
  int get daysLeft {
    if (accessUntil == null) return 0;
    final d = accessUntil!.difference(DateTime.now());
    return d.isNegative ? 0 : (d.inHours / 24).ceil();
  }

  factory ClientAccount.fromJson(Map<String, dynamic> j) => ClientAccount(
        id: j['id'] as String,
        displayName: j['displayName'] as String,
        email: j['email'] as String?,
        // /v1/client/me does not send isActive (an inactive client cannot reach it).
        isActive: (j['isActive'] as bool?) ?? true,
        loginCodeExpiresAt: _date(j['loginCodeExpiresAt']),
        lastLoginAt: _date(j['lastLoginAt']),
        plan: j['plan'] as String?,
        accessUntil: _date(j['accessUntil']),
        testExpiryEnabled: j['testExpiryEnabled'] == true,
        testAccessUntil: _date(j['testAccessUntil']),
        regularAccessUntil: _date(j['regularAccessUntil']),
      );

  static DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
}
