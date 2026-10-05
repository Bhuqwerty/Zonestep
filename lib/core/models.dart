import 'dart:convert';

import 'plan.dart';

class HrSample {
  HrSample(this.tMs, this.bpm, this.contact);
  final int tMs;
  final int bpm;
  final bool contact;
}

class RrPoint {
  RrPoint(this.tMs, this.rr);
  final int tMs;
  final double rr;
}

class GpsPoint {
  GpsPoint({
    required this.tMs,
    required this.lat,
    required this.lon,
    this.alt,
    this.acc,
    required this.dist,
    this.moving = true,
  });
  final int tMs;
  final double lat;
  final double lon;
  final double? alt;
  final double? acc;

  /// Cumulative distance in metres at this fix.
  final double dist;
  final bool moving;
}

class AlertLogEntry {
  AlertLogEntry(this.tMs, this.type, this.message);
  final int tMs;
  final String type;
  final String message;
}

class IntakeEntry {
  IntakeEntry(this.tMs, this.kind, this.amount);
  final int tMs;

  /// carb | water
  final String kind;
  final double amount;
}

class DeviceRecord {
  DeviceRecord({
    required this.id,
    required this.name,
    this.kind = 'strap',
    this.lastBattery,
    this.bodyLocation,
    this.testResult,
    this.testAt,
    this.rrSupported,
    this.contactSupported,
    this.lastUsed,
  });

  final String id;
  String name;

  /// strap | watch
  String kind;
  int? lastBattery;
  String? bodyLocation;

  /// ready | limits | problem, plus details in [testDetails].
  String? testResult;
  DateTime? testAt;
  bool? rrSupported;
  bool? contactSupported;
  DateTime? lastUsed;
  Map<String, dynamic> testDetails = {};

  bool get isWatch => kind == 'watch';

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'kind': kind,
        'last_battery': lastBattery,
        'body_location': bodyLocation,
        'test_result': testResult,
        'test_at': testAt?.millisecondsSinceEpoch,
        'rr_supported': rrSupported == null ? null : (rrSupported! ? 1 : 0),
        'contact_supported': contactSupported == null ? null : (contactSupported! ? 1 : 0),
        'last_used': lastUsed?.millisecondsSinceEpoch,
        'test_details': jsonEncode(testDetails),
      };

  factory DeviceRecord.fromRow(Map<String, Object?> r) {
    bool? b(Object? v) => v == null ? null : v == 1;
    DateTime? d(Object? v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
    return DeviceRecord(
      id: r['id'] as String,
      name: r['name'] as String,
      kind: r['kind'] as String? ?? 'strap',
      lastBattery: r['last_battery'] as int?,
      bodyLocation: r['body_location'] as String?,
      testResult: r['test_result'] as String?,
      testAt: d(r['test_at']),
      rrSupported: b(r['rr_supported']),
      contactSupported: b(r['contact_supported']),
      lastUsed: d(r['last_used']),
    )..testDetails = r['test_details'] == null
        ? {}
        : (jsonDecode(r['test_details'] as String) as Map).cast<String, dynamic>();
  }
}

class SessionRecord {
  SessionRecord({
    this.id,
    required this.kind,
    required this.activity,
    required this.start,
    this.end,
    this.goalDistanceM,
    this.goalTime,
    this.plan,
    this.deviceId,
    this.deviceKind,
    this.movingS = 0,
    this.summary,
    this.recoveryStartBpm,
    this.recoveryEndBpm,
    this.manualDistanceM,
    this.manualWatts,
    this.muted = const [],
  });

  int? id;
  SessionKind kind;
  String activity;
  DateTime start;
  DateTime? end;
  double? goalDistanceM;
  Duration? goalTime;
  AlertPlan? plan;
  String? deviceId;
  String? deviceKind;
  double movingS;
  Map<String, dynamic>? summary;
  int? recoveryStartBpm;
  int? recoveryEndBpm;
  double? manualDistanceM;
  double? manualWatts;
  List<String> muted;

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'kind': kind.name,
        'activity': activity,
        'start': start.millisecondsSinceEpoch,
        'end': end?.millisecondsSinceEpoch,
        'goal_distance': goalDistanceM,
        'goal_time': goalTime?.inSeconds,
        'plan_json': plan?.encode(),
        'device_id': deviceId,
        'device_kind': deviceKind,
        'moving_s': movingS,
        'summary': summary == null ? null : jsonEncode(_finite(summary)),
        'recovery_start': recoveryStartBpm,
        'recovery_end': recoveryEndBpm,
        'manual_distance': manualDistanceM,
        'manual_watts': manualWatts,
        'muted': jsonEncode(muted),
      };

  factory SessionRecord.fromRow(Map<String, Object?> r) => SessionRecord(
        id: r['id'] as int?,
        kind: SessionKind.values.byName(r['kind'] as String),
        activity: r['activity'] as String,
        start: DateTime.fromMillisecondsSinceEpoch(r['start'] as int),
        end: r['end'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['end'] as int),
        goalDistanceM: (r['goal_distance'] as num?)?.toDouble(),
        goalTime: r['goal_time'] == null ? null : Duration(seconds: r['goal_time'] as int),
        plan: r['plan_json'] == null ? null : AlertPlan.decode(r['plan_json'] as String),
        deviceId: r['device_id'] as String?,
        deviceKind: r['device_kind'] as String?,
        movingS: (r['moving_s'] as num?)?.toDouble() ?? 0,
        summary: r['summary'] == null ? null : (jsonDecode(r['summary'] as String) as Map).cast<String, dynamic>(),
        recoveryStartBpm: r['recovery_start'] as int?,
        recoveryEndBpm: r['recovery_end'] as int?,
        manualDistanceM: (r['manual_distance'] as num?)?.toDouble(),
        manualWatts: (r['manual_watts'] as num?)?.toDouble(),
        muted: r['muted'] == null ? [] : (jsonDecode(r['muted'] as String) as List).cast<String>(),
      );
}

/// JSON cannot hold NaN or infinity; drop them rather than fail the save.
Object? _finite(Object? v) {
  if (v is double) return v.isFinite ? v : null;
  if (v is Map) return {for (final e in v.entries) e.key.toString(): _finite(e.value)};
  if (v is List) return [for (final x in v) _finite(x)];
  return v;
}

class SessionData {
  SessionData({
    required this.session,
    required this.hr,
    required this.rr,
    required this.gps,
    required this.alerts,
    required this.intake,
  });
  final SessionRecord session;
  final List<HrSample> hr;
  final List<RrPoint> rr;
  final List<GpsPoint> gps;
  final List<AlertLogEntry> alerts;
  final List<IntakeEntry> intake;
}
