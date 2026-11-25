import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import 'models.dart';
import 'ops.dart';

/// An operation the server refused (for example a number was blocked in the meantime).
class FailedOp {
  FailedOp(this.op, this.code, this.message);
  final Op op;
  final String code;
  final String message;
  Map<String, dynamic> toJson() => {'op': op, 'code': code, 'message': message};
  factory FailedOp.fromJson(Map<String, dynamic> j) =>
      FailedOp(Map<String, dynamic>.from(j['op'] as Map), j['code'] as String, j['message'] as String);

  /// Short human description of what was lost, e.g. "entry.create".
  String get what => op['type'] as String;
}

/// The client's ledger on the phone.
///
///  * [data] is what the screens show: the last server snapshot + every not-yet-synced operation.
///  * Every change is an [Op] saved to disk first, then sent to the server in order.
///  * The server is authoritative: after a sync the phone replaces its copy with the server snapshot.
///  * Because each op has its own id, sending it twice (lost connection, app killed) never duplicates it.
class LedgerStore extends ChangeNotifier {
  LedgerStore({required this.api, required this.file, required this.owner});

  final ApiClient api;
  final File file;

  /// Who this local copy belongs to (the login e-mail); another client's data is never reused.
  final String owner;

  LedgerData _base = LedgerData();
  LedgerData data = LedgerData();
  final List<Op> _queue = [];
  final List<FailedOp> failed = [];

  bool loaded = false;
  bool syncing = false;
  bool everSynced = false;

  // ---- Offline plan check (v0.7.1). The server is the real check; this stops "never go online" use.
  /// How long the phone may work without reaching the server.
  static const offlineGrace = Duration(days: 7);

  /// Plan end date last told by the server (null until known).
  DateTime? accessUntil;

  /// Last time the server answered (phone clock).
  DateTime? lastServerContact;

  /// Latest phone time ever seen — if the clock is moved back past this, the ledger locks.
  DateTime? lastSeen;

  /// Why changes are blocked right now: 'PLAN_EXPIRED', 'OFFLINE_TOO_LONG', 'CLOCK_CHANGED' — or null when fine.
  String? lockReason([DateTime? at]) {
    final now = at ?? DateTime.now();
    if (lastSeen != null && now.isBefore(lastSeen!.subtract(const Duration(hours: 12)))) return 'CLOCK_CHANGED';
    if (accessUntil != null && !now.isBefore(accessUntil!)) return 'PLAN_EXPIRED';
    if (lastServerContact != null && now.difference(lastServerContact!) > offlineGrace) return 'OFFLINE_TOO_LONG';
    return null;
  }

  void _touchClock() {
    final now = DateTime.now();
    if (lastSeen == null || now.isAfter(lastSeen!)) lastSeen = now;
  }
  String? lastError; // last sync problem (offline, server error), null when fine
  String? lastErrorCode; // server error code, e.g. PLAN_EXPIRED
  Timer? _timer;
  bool _disposed = false;
  Future<void> _saveTail = Future<void>.value();

  int get pending => _queue.length;
  bool get hasUnsynced => _queue.isNotEmpty;

  // ------------------------------------------------------------------ lifecycle
  Future<void> start() async {
    await _load();
    // Only remember a newer time; an older one (clock moved back) is what lockReason() looks for.
    _touchClock();
    loaded = true;
    _notify();
    unawaited(sync());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => sync());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ------------------------------------------------------------------ persistence
  Future<void> _load() async {
    try {
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (j['owner'] == owner) {
          _base = LedgerData.fromJson(j['base'] as Map<String, dynamic>);
          _queue.addAll((j['queue'] as List).map((x) => Map<String, dynamic>.from(x as Map)));
          failed.addAll((j['failed'] as List).map((x) => FailedOp.fromJson(x as Map<String, dynamic>)));
          everSynced = j['everSynced'] == true;
          DateTime? d(Object? v) => v == null ? null : DateTime.tryParse(v as String);
          accessUntil = d(j['accessUntil']);
          lastServerContact = d(j['lastServerContact']);
          lastSeen = d(j['lastSeen']);
        }
      }
    } catch (_) {
      // A damaged file must never lock the user out: start empty and let the server snapshot refill it.
      // (Unsynced operations in a damaged file cannot be recovered.)
      _base = LedgerData();
      _queue.clear();
      failed.clear();
    }
    _rebuild();
  }

  /// Serialize writes from local operations and sync before replacing the on-disk copy.
  Future<void> _save() {
    final write = _saveTail.then((_) => _writeSnapshot(), onError: (Object _, StackTrace __) => _writeSnapshot());
    _saveTail = write;
    return write;
  }

  /// Write to a temp file then rename, so a crash mid-write can't leave a half-written ledger.
  Future<void> _writeSnapshot() async {
    final tmp = File('${file.path}.tmp');
    await file.parent.create(recursive: true);
    await tmp.writeAsString(jsonEncode({
      'owner': owner,
      'everSynced': everSynced,
      'accessUntil': accessUntil?.toUtc().toIso8601String(),
      'lastServerContact': lastServerContact?.toUtc().toIso8601String(),
      'lastSeen': lastSeen?.toUtc().toIso8601String(),
      'base': _base.toJson(),
      'queue': _queue,
      'failed': failed.map((f) => f.toJson()).toList(),
    }), flush: true);
    await tmp.rename(file.path);
  }

  void _rebuild() {
    final d = _base.copy();
    for (final op in _queue) {
      try {
        applyOpLocally(d, op);
      } on LedgerRule {
        // The server will reject it too and report it in [failed].
      } catch (e) {
        debugPrint('Skipping a queued operation that cannot be shown locally: $e');
      }
    }
    data = d;
  }

  // ------------------------------------------------------------------ changes
  /// Validates, applies, saves and queues an operation. Throws [LedgerRule] (and changes nothing) when the rules refuse it.
  Future<void> run(Op op) => runAll([op]);

  /// Validates the whole selection before updating the local copy and sync queue.
  Future<void> runAll(List<Op> ops) async {
    if (ops.isEmpty) return;
    final lock = lockReason();
    if (lock != null) throw LedgerRule(lock, 'Changes are blocked: $lock');
    _touchClock();
    final d = data.copy();
    for (final op in ops) {
      applyOpLocally(d, op); // may throw LedgerRule
    }
    data = d;
    _queue.addAll(ops);
    _notify();
    await _save();
    unawaited(sync());
  }

  void dismissFailed(FailedOp f) {
    failed.remove(f);
    _notify();
    unawaited(_save());
  }

  void dismissAllFailed() {
    failed.clear();
    _notify();
    unawaited(_save());
  }

  // ------------------------------------------------------------------ sync
  Future<void> sync() async {
    if (syncing || _disposed) return;
    syncing = true;
    _notify();
    try {
      while (_queue.isNotEmpty) {
        final batch = _queue.take(50).toList();
        final res = await api.post('/v1/client/ledger/sync', {'ops': batch}) as Map<String, dynamic>;
        final results = (res['results'] as List).map((x) => x as Map<String, dynamic>).toList();
        final byId = {for (final r in results) r['opId']: r};
        for (final op in batch) {
          final r = byId[op['opId']];
          if (r == null) continue; // not answered: keep it queued, it will be retried
          _queue.remove(op);
          if (r['status'] != 'ok') {
            failed.add(FailedOp(op, (r['code'] ?? 'ERROR') as String, (r['message'] ?? 'Rejected by the server.') as String));
          }
        }
        if (batch.every((op) => byId[op['opId']] == null)) break; // nothing progressed; avoid a tight loop
        await _save();
      }
      final snap = await api.get('/v1/client/ledger/snapshot') as Map<String, dynamic>;
      // The server answered: refresh the plan end date and the offline timer.
      try {
        final me = await api.get('/v1/client/me') as Map<String, dynamic>;
        accessUntil = me['accessUntil'] == null ? null : DateTime.tryParse(me['accessUntil'] as String);
      } catch (_) {}
      lastServerContact = DateTime.now();
      _touchClock();
      _base = LedgerData.fromJson(snap);
      everSynced = true;
      _rebuild(); // re-applies anything queued while we were syncing
      lastError = null;
      lastErrorCode = null;
      await _save();
    } on NetworkException {
      lastError = 'Offline — changes are saved on this phone and will sync later.';
    } on ApiException catch (e) {
      lastError = e.message;
      lastErrorCode = e.code;
      if (e.code == 'PLAN_EXPIRED') {
        // The server says the plan is over: lock right away, and remember it for offline use.
        lastServerContact = DateTime.now();
        accessUntil = DateTime.now().subtract(const Duration(seconds: 1));
        try {
          await _save();
        } catch (_) {}
      }
    } catch (e) {
      lastError = e.toString();
    } finally {
      syncing = false;
      _notify();
    }
  }

  /// Removes the local copy (used after sign-out when nothing is waiting to sync).
  Future<void> wipe() async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
