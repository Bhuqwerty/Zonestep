import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../core/models.dart';
import '../core/plan.dart';
import '../core/profile.dart';

/// The one encrypted SQLite database (SQLCipher). Its random key lives in
/// the Android Keystore via flutter_secure_storage, never in app files.
class AppDb {
  AppDb._(this.db);

  final Database db;
  static AppDb? _instance;
  static AppDb get I => _instance!;

  static const _keyName = 'zonestep_db_key';
  static const _fileName = 'zonestep.db';
  static const _storage = FlutterSecureStorage();

  static Future<AppDb> open() async {
    if (_instance != null) return _instance!;
    var key = await _storage.read(key: _keyName);
    final path = p.join(await getDatabasesPath(), _fileName);
    if (key == null) {
      // A database without its key is unreadable; start fresh.
      if (await File(path).exists()) await File(path).delete();
      final rnd = Random.secure();
      key = List.generate(32, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await _storage.write(key: _keyName, value: key);
    }
    final db = await openDatabase(
      path,
      password: key,
      version: 1,
      onCreate: (db, v) async {
        final b = db.batch();
        b.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)');
        b.execute('''CREATE TABLE devices (
          id TEXT PRIMARY KEY, name TEXT, kind TEXT, last_battery INTEGER, body_location TEXT,
          test_result TEXT, test_at INTEGER, rr_supported INTEGER, contact_supported INTEGER,
          last_used INTEGER, test_details TEXT)''');
        b.execute('''CREATE TABLE sessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, activity TEXT, start INTEGER, end INTEGER,
          goal_distance REAL, goal_time INTEGER, plan_json TEXT, device_id TEXT, device_kind TEXT,
          moving_s REAL, summary TEXT, recovery_start INTEGER, recovery_end INTEGER,
          manual_distance REAL, manual_watts REAL, muted TEXT)''');
        b.execute('CREATE TABLE hr_samples (session_id INTEGER, t INTEGER, bpm INTEGER, contact INTEGER)');
        b.execute('CREATE INDEX hr_s ON hr_samples(session_id, t)');
        b.execute('CREATE TABLE rr_intervals (session_id INTEGER, t INTEGER, rr REAL)');
        b.execute('CREATE INDEX rr_s ON rr_intervals(session_id, t)');
        b.execute('''CREATE TABLE gps_points (session_id INTEGER, t INTEGER, lat REAL, lon REAL,
          alt REAL, acc REAL, dist REAL, moving INTEGER)''');
        b.execute('CREATE INDEX gps_s ON gps_points(session_id, t)');
        b.execute('''CREATE TABLE splits (session_id INTEGER, idx INTEGER, time_s REAL, pace REAL,
          avg_hr REAL, max_hr INTEGER, elev REAL)''');
        b.execute('CREATE TABLE alerts_log (session_id INTEGER, t INTEGER, type TEXT, message TEXT)');
        b.execute('CREATE TABLE intake_log (session_id INTEGER, t INTEGER, kind TEXT, amount REAL)');
        b.execute('''CREATE TABLE alert_plans (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, kind TEXT,
          distance_m REAL, is_default INTEGER, json TEXT)''');
        await b.commit(noResult: true);
      },
    );
    _instance = AppDb._(db);
    return _instance!;
  }

  /// Wipes the database file and its key.
  static Future<void> deleteEverything() async {
    final path = p.join(await getDatabasesPath(), _fileName);
    await _instance?.db.close();
    _instance = null;
    if (await File(path).exists()) await File(path).delete();
    await _storage.delete(key: _keyName);
  }

  // --- Settings ---------------------------------------------------------------

  Future<String?> getSetting(String key) async {
    final r = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  Future<void> setSetting(String key, String? value) =>
      db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<Profile> loadProfile() async {
    final s = await getSetting('profile');
    return s == null ? Profile() : Profile.decode(s);
  }

  Future<void> saveProfile(Profile p) => setSetting('profile', p.encode());

  // --- Devices ----------------------------------------------------------------

  Future<List<DeviceRecord>> devices() async {
    final r = await db.query('devices', orderBy: 'last_used DESC');
    return r.map(DeviceRecord.fromRow).toList();
  }

  Future<DeviceRecord?> device(String id) async {
    final r = await db.query('devices', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : DeviceRecord.fromRow(r.first);
  }

  Future<void> saveDevice(DeviceRecord d) =>
      db.insert('devices', d.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteDevice(String id) => db.delete('devices', where: 'id = ?', whereArgs: [id]);

  // --- Sessions ---------------------------------------------------------------

  Future<int> insertSession(SessionRecord s) => db.insert('sessions', s.toRow());

  Future<void> updateSession(SessionRecord s) =>
      db.update('sessions', s.toRow(), where: 'id = ?', whereArgs: [s.id]);

  Future<List<SessionRecord>> sessions({int? limit}) async {
    final r = await db.query('sessions', where: 'end IS NOT NULL', orderBy: 'start DESC', limit: limit);
    return r.map(SessionRecord.fromRow).toList();
  }

  Future<SessionRecord?> session(int id) async {
    final r = await db.query('sessions', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : SessionRecord.fromRow(r.first);
  }

  /// Sessions that never got an end time (app killed mid-run).
  Future<List<SessionRecord>> unfinishedSessions() async {
    final r = await db.query('sessions', where: 'end IS NULL');
    return r.map(SessionRecord.fromRow).toList();
  }

  Future<void> deleteSession(int id) async {
    final b = db.batch();
    for (final t in ['hr_samples', 'rr_intervals', 'gps_points', 'splits', 'alerts_log', 'intake_log']) {
      b.delete(t, where: 'session_id = ?', whereArgs: [id]);
    }
    b.delete('sessions', where: 'id = ?', whereArgs: [id]);
    await b.commit(noResult: true);
  }

  Future<void> writeSamples({
    required int sessionId,
    required List<HrSample> hr,
    required List<RrPoint> rr,
    required List<GpsPoint> gps,
    required List<AlertLogEntry> alerts,
    required List<IntakeEntry> intake,
  }) async {
    if (hr.isEmpty && rr.isEmpty && gps.isEmpty && alerts.isEmpty && intake.isEmpty) return;
    final b = db.batch();
    for (final h in hr) {
      b.insert('hr_samples', {'session_id': sessionId, 't': h.tMs, 'bpm': h.bpm, 'contact': h.contact ? 1 : 0});
    }
    for (final r in rr) {
      b.insert('rr_intervals', {'session_id': sessionId, 't': r.tMs, 'rr': r.rr});
    }
    for (final g in gps) {
      b.insert('gps_points', {
        'session_id': sessionId,
        't': g.tMs,
        'lat': g.lat,
        'lon': g.lon,
        'alt': g.alt,
        'acc': g.acc,
        'dist': g.dist,
        'moving': g.moving ? 1 : 0,
      });
    }
    for (final a in alerts) {
      b.insert('alerts_log', {'session_id': sessionId, 't': a.tMs, 'type': a.type, 'message': a.message});
    }
    for (final i in intake) {
      b.insert('intake_log', {'session_id': sessionId, 't': i.tMs, 'kind': i.kind, 'amount': i.amount});
    }
    await b.commit(noResult: true);
  }

  Future<void> saveSplits(int sessionId, List<Map<String, dynamic>> splits) async {
    final b = db.batch();
    b.delete('splits', where: 'session_id = ?', whereArgs: [sessionId]);
    for (final s in splits) {
      b.insert('splits', {
        'session_id': sessionId,
        'idx': s['index'],
        'time_s': s['seconds'],
        'pace': s['pace'],
        'avg_hr': s['avgHr'],
        'max_hr': s['maxHr'],
        'elev': s['elev'],
      });
    }
    await b.commit(noResult: true);
  }

  Future<SessionData> loadData(SessionRecord s) async {
    final id = s.id!;
    final hr = await db.query('hr_samples', where: 'session_id = ?', whereArgs: [id], orderBy: 't');
    final rr = await db.query('rr_intervals', where: 'session_id = ?', whereArgs: [id], orderBy: 't');
    final gps = await db.query('gps_points', where: 'session_id = ?', whereArgs: [id], orderBy: 't');
    final al = await db.query('alerts_log', where: 'session_id = ?', whereArgs: [id], orderBy: 't');
    final il = await db.query('intake_log', where: 'session_id = ?', whereArgs: [id], orderBy: 't');
    return SessionData(
      session: s,
      hr: hr.map((r) => HrSample(r['t'] as int, r['bpm'] as int, r['contact'] == 1)).toList(),
      rr: rr.map((r) => RrPoint(r['t'] as int, (r['rr'] as num).toDouble())).toList(),
      gps: gps
          .map((r) => GpsPoint(
                tMs: r['t'] as int,
                lat: (r['lat'] as num).toDouble(),
                lon: (r['lon'] as num).toDouble(),
                alt: (r['alt'] as num?)?.toDouble(),
                acc: (r['acc'] as num?)?.toDouble(),
                dist: (r['dist'] as num).toDouble(),
                moving: r['moving'] == 1,
              ))
          .toList(),
      alerts: al.map((r) => AlertLogEntry(r['t'] as int, r['type'] as String, r['message'] as String)).toList(),
      intake: il.map((r) => IntakeEntry(r['t'] as int, r['kind'] as String, (r['amount'] as num).toDouble())).toList(),
    );
  }

  /// Last sample time for a session, used to close sessions after a crash.
  Future<int?> lastSampleT(int sessionId) async {
    final h = await db.rawQuery('SELECT MAX(t) AS t FROM hr_samples WHERE session_id = ?', [sessionId]);
    final g = await db.rawQuery('SELECT MAX(t) AS t FROM gps_points WHERE session_id = ?', [sessionId]);
    final a = h.first['t'] as int?, b = g.first['t'] as int?;
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }

  // --- Plans ------------------------------------------------------------------

  Future<List<AlertPlan>> plans({SessionKind? kind}) async {
    final r = await db.query('alert_plans',
        where: kind == null ? null : 'kind = ?', whereArgs: kind == null ? null : [kind.name], orderBy: 'name');
    return r.map((row) => AlertPlan.decode(row['json'] as String)..id = row['id'] as int).toList();
  }

  Future<int> savePlan(AlertPlan plan) async {
    if (plan.isDefault && plan.distanceM != null) {
      // Only one default per distance.
      for (final other in await plans(kind: plan.kind)) {
        if (other.id != plan.id && other.isDefault && other.distanceM == plan.distanceM) {
          other.isDefault = false;
          await db.update('alert_plans', {'is_default': 0, 'json': other.encode()},
              where: 'id = ?', whereArgs: [other.id]);
        }
      }
    }
    final row = {
      'name': plan.name,
      'kind': plan.kind.name,
      'distance_m': plan.distanceM,
      'is_default': plan.isDefault ? 1 : 0,
      'json': plan.encode(),
    };
    if (plan.id == null) {
      plan.id = await db.insert('alert_plans', row);
      await db.update('alert_plans', {'json': plan.encode()}, where: 'id = ?', whereArgs: [plan.id]);
    } else {
      await db.update('alert_plans', row, where: 'id = ?', whereArgs: [plan.id]);
    }
    return plan.id!;
  }

  Future<void> deletePlan(int id) => db.delete('alert_plans', where: 'id = ?', whereArgs: [id]);

  Future<AlertPlan?> defaultPlanFor(double distanceM) async {
    final r = await db.query('alert_plans',
        where: 'is_default = 1 AND kind = ? AND ABS(distance_m - ?) < 1', whereArgs: ['run', distanceM]);
    return r.isEmpty ? null : (AlertPlan.decode(r.first['json'] as String)..id = r.first['id'] as int);
  }
}
