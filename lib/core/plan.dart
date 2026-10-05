import 'dart:convert';

import 'formulas.dart';
import 'zones.dart';

enum SessionKind { run, hrOnly }

enum PlanAxis { distance, time }

enum RuleDelivery { voice, vibrate, notification, log }

enum TriggerKind {
  atDistance,
  atTime,
  everyDistance,
  everyTime,
  hrAbove,
  hrBelow,
  enterZone,
  leaveZone,
  paceFaster,
  paceSlower,
  segmentStart,
  segmentEnd,
}

const triggerLabels = {
  TriggerKind.atDistance: 'At a distance',
  TriggerKind.atTime: 'At a time',
  TriggerKind.everyDistance: 'Every X distance',
  TriggerKind.everyTime: 'Every X minutes',
  TriggerKind.hrAbove: 'Heart rate above',
  TriggerKind.hrBelow: 'Heart rate below',
  TriggerKind.enterZone: 'Entering a zone',
  TriggerKind.leaveZone: 'Leaving a zone',
  TriggerKind.paceFaster: 'Pace faster than',
  TriggerKind.paceSlower: 'Pace slower than',
  TriggerKind.segmentStart: 'Start of a segment',
  TriggerKind.segmentEnd: 'End of a segment',
};

/// Built-in coach alerts. Each can be switched off in a plan.
enum BuiltIn {
  hrHigh('Above ceiling / target', 3),
  hrLow('Below floor / target', 4),
  zoneChange('Zone change', 6),
  split('Splits', 5),
  projection('Finish projection', 5),
  drift('Drift warning', 5),
  finalPush('Final push', 5),
  sustainability('Pace sustainability', 4),
  sensor('Sensor lost / battery low', 1),
  flatline('Stuck reading check', 2),
  safety('Long time above ceiling', 1),
  calories('Calories every 100 kcal', 7),
  timeInZone('Time-in-zone progress', 5),
  recovered('Ready for next set', 4),
  intervals('Interval timer', 2);

  const BuiltIn(this.label, this.priority);
  final String label;

  /// Lower number speaks first when two alerts fire together.
  final int priority;

  static const safetyCritical = {BuiltIn.sensor, BuiltIn.safety, BuiltIn.flatline};
}

class Segment {
  Segment({
    required this.name,
    required this.start,
    required this.end,
    required this.zoneLow,
    required this.zoneHigh,
    this.ceiling,
    this.floor,
    this.paceSecPerKm,
  });

  String name;

  /// Metres (distance plans) or seconds (time plans).
  double start;
  double end;
  int zoneLow;
  int zoneHigh;
  int? ceiling;
  int? floor;
  double? paceSecPerKm;

  int ceilingBpm(ZoneModel z) => ceiling ?? z.highBpm(zoneHigh);
  int floorBpm(ZoneModel z) => floor ?? z.lowBpm(zoneLow);

  Map<String, dynamic> toJson() => {
        'name': name,
        'start': start,
        'end': end,
        'zoneLow': zoneLow,
        'zoneHigh': zoneHigh,
        'ceiling': ceiling,
        'floor': floor,
        'pace': paceSecPerKm,
      };

  factory Segment.fromJson(Map<String, dynamic> j) => Segment(
        name: j['name'] as String,
        start: (j['start'] as num).toDouble(),
        end: (j['end'] as num).toDouble(),
        zoneLow: j['zoneLow'] as int,
        zoneHigh: j['zoneHigh'] as int,
        ceiling: j['ceiling'] as int?,
        floor: j['floor'] as int?,
        paceSecPerKm: (j['pace'] as num?)?.toDouble(),
      );

  Segment copy() => Segment.fromJson(toJson());
}

class AlertRule {
  AlertRule({
    required this.id,
    required this.trigger,
    required this.message,
    this.value = 0,
    this.holdSec = 0,
    this.zone,
    this.segment,
    this.delivery = RuleDelivery.voice,
    this.cooldownSec = 45,
    this.maxRepeats,
    this.enabled = true,
    this.category = 'custom',
    this.priority = 5,
  });

  String id;
  TriggerKind trigger;

  /// Metres, seconds, BPM or seconds per km depending on [trigger].
  double value;
  int holdSec;
  int? zone;

  /// Only active during this segment index when set.
  int? segment;
  String message;
  RuleDelivery delivery;
  int cooldownSec;
  int? maxRepeats;
  bool enabled;

  /// custom | carb | water
  String category;
  int priority;

  Map<String, dynamic> toJson() => {
        'id': id,
        'trigger': trigger.name,
        'value': value,
        'holdSec': holdSec,
        'zone': zone,
        'segment': segment,
        'message': message,
        'delivery': delivery.name,
        'cooldownSec': cooldownSec,
        'maxRepeats': maxRepeats,
        'enabled': enabled,
        'category': category,
        'priority': priority,
      };

  factory AlertRule.fromJson(Map<String, dynamic> j) => AlertRule(
        id: j['id'] as String,
        trigger: TriggerKind.values.byName(j['trigger'] as String),
        value: (j['value'] as num).toDouble(),
        holdSec: j['holdSec'] as int? ?? 0,
        zone: j['zone'] as int?,
        segment: j['segment'] as int?,
        message: j['message'] as String,
        delivery: RuleDelivery.values.byName(j['delivery'] as String),
        cooldownSec: j['cooldownSec'] as int? ?? 45,
        maxRepeats: j['maxRepeats'] as int?,
        enabled: j['enabled'] as bool? ?? true,
        category: j['category'] as String? ?? 'custom',
        priority: j['priority'] as int? ?? 5,
      );

  AlertRule copy() => AlertRule.fromJson(toJson());
}

class IntervalTimer {
  IntervalTimer({required this.workSec, required this.restSec, required this.rounds, this.endRestOnRecovery = false});
  int workSec;
  int restSec;
  int rounds;
  bool endRestOnRecovery;

  Map<String, dynamic> toJson() =>
      {'work': workSec, 'rest': restSec, 'rounds': rounds, 'early': endRestOnRecovery};
  factory IntervalTimer.fromJson(Map<String, dynamic> j) => IntervalTimer(
      workSec: j['work'] as int,
      restSec: j['rest'] as int,
      rounds: j['rounds'] as int,
      endRestOnRecovery: j['early'] as bool? ?? false);
}

class AlertPlan {
  AlertPlan({
    this.id,
    required this.name,
    required this.kind,
    required this.axis,
    this.distanceM,
    this.goalTime,
    required this.segments,
    required this.rules,
    Map<BuiltIn, bool>? builtIns,
    Map<BuiltIn, int>? cooldowns,
    this.isDefault = false,
    this.activity = 'Run',
    this.timeInZoneGoal,
    this.intervals,
    this.kcalWithSplit = true,
    this.ultra = false,
  })  : builtIns = builtIns ?? {for (final b in BuiltIn.values) b: true},
        cooldowns = cooldowns ?? {};

  int? id;
  String name;
  SessionKind kind;
  PlanAxis axis;
  double? distanceM;
  Duration? goalTime;
  List<Segment> segments;
  List<AlertRule> rules;
  Map<BuiltIn, bool> builtIns;
  Map<BuiltIn, int> cooldowns;
  bool isDefault;
  String activity;

  /// HR-only: (zone, minutes) goal.
  ({int zone, int minutes})? timeInZoneGoal;
  IntervalTimer? intervals;
  bool kcalWithSplit;
  bool ultra;

  bool on(BuiltIn b) => builtIns[b] ?? true;
  int cooldown(BuiltIn b, int fallback) => cooldowns[b] ?? fallback;

  /// The segment at a given position (metres or seconds).
  int segmentIndexAt(double pos) {
    if (segments.isEmpty) return -1;
    for (var i = 0; i < segments.length; i++) {
      if (pos < segments[i].end) return i;
    }
    return segments.length - 1;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'axis': axis.name,
        'distanceM': distanceM,
        'goalS': goalTime?.inSeconds,
        'segments': segments.map((s) => s.toJson()).toList(),
        'rules': rules.map((r) => r.toJson()).toList(),
        'builtIns': {for (final e in builtIns.entries) e.key.name: e.value},
        'cooldowns': {for (final e in cooldowns.entries) e.key.name: e.value},
        'isDefault': isDefault,
        'activity': activity,
        'tiz': timeInZoneGoal == null
            ? null
            : {'zone': timeInZoneGoal!.zone, 'minutes': timeInZoneGoal!.minutes},
        'intervals': intervals?.toJson(),
        'kcalWithSplit': kcalWithSplit,
        'ultra': ultra,
      };

  factory AlertPlan.fromJson(Map<String, dynamic> j) {
    final b = (j['builtIns'] as Map?)?.cast<String, dynamic>() ?? {};
    final c = (j['cooldowns'] as Map?)?.cast<String, dynamic>() ?? {};
    final tiz = j['tiz'] as Map?;
    return AlertPlan(
      id: j['id'] as int?,
      name: j['name'] as String,
      kind: SessionKind.values.byName(j['kind'] as String),
      axis: PlanAxis.values.byName(j['axis'] as String),
      distanceM: (j['distanceM'] as num?)?.toDouble(),
      goalTime: j['goalS'] == null ? null : Duration(seconds: j['goalS'] as int),
      segments: (j['segments'] as List).map((s) => Segment.fromJson((s as Map).cast())).toList(),
      rules: (j['rules'] as List).map((r) => AlertRule.fromJson((r as Map).cast())).toList(),
      builtIns: {
        for (final v in BuiltIn.values) v: b[v.name] as bool? ?? true,
      },
      cooldowns: {
        for (final e in c.entries)
          if (BuiltIn.values.any((v) => v.name == e.key)) BuiltIn.values.byName(e.key): e.value as int,
      },
      isDefault: j['isDefault'] as bool? ?? false,
      activity: j['activity'] as String? ?? 'Run',
      timeInZoneGoal: tiz == null ? null : (zone: tiz['zone'] as int, minutes: tiz['minutes'] as int),
      intervals: j['intervals'] == null ? null : IntervalTimer.fromJson((j['intervals'] as Map).cast()),
      kcalWithSplit: j['kcalWithSplit'] as bool? ?? true,
      ultra: j['ultra'] as bool? ?? false,
    );
  }

  String encode() => jsonEncode(toJson());
  static AlertPlan decode(String s) => AlertPlan.fromJson(jsonDecode(s) as Map<String, dynamic>);
  AlertPlan copy() => decode(encode());
}

int _ruleSeq = 0;
String newRuleId() => '${DateTime.now().microsecondsSinceEpoch}-${_ruleSeq++}';

/// Drafts a run plan from distance and optional goal time: warm-up, main
/// block and finish, plus fuel and water reminders.
AlertPlan suggestRunPlan({
  required double distanceM,
  Duration? goalTime,
  bool firstTime = false,
  double gelGrams = 25,
  bool carbs = true,
  bool water = true,
  bool hotDay = false,
  double? sweatRateLph,
}) {
  final (lo, hi) = suggestedTargetZone(distanceM, firstTime: firstTime);
  final pace = goalTime == null ? null : goalTime.inSeconds / (distanceM / 1000);
  final segs = <Segment>[];
  if (distanceM < 3000) {
    final b = distanceM * 0.8;
    segs.add(Segment(name: 'Main', start: 0, end: b, zoneLow: 4, zoneHigh: 4, paceSecPerKm: pace));
    segs.add(Segment(name: 'Finish', start: b, end: distanceM, zoneLow: 4, zoneHigh: 5, paceSecPerKm: pace));
  } else {
    final warm = (distanceM * 0.2).clamp(1000, 5000).toDouble();
    final finish = distanceM > 30000 ? distanceM * 0.1 : (distanceM * 0.2).clamp(500, 3000).toDouble();
    segs.add(Segment(
        name: 'Warm-up', start: 0, end: warm, zoneLow: (lo - 1).clamp(1, 5), zoneHigh: lo,
        paceSecPerKm: pace == null ? null : pace + 15));
    segs.add(Segment(name: 'Main block', start: warm, end: distanceM - finish, zoneLow: lo, zoneHigh: hi, paceSecPerKm: pace));
    segs.add(Segment(
        name: 'Finish', start: distanceM - finish, end: distanceM, zoneLow: lo, zoneHigh: (hi + 1).clamp(1, 5),
        paceSecPerKm: pace == null ? null : pace - 5));
  }

  final rules = <AlertRule>[];
  final expected = goalTime ?? Duration(seconds: (distanceM / 1000 * 360).round());
  if (carbs) {
    final interval = carbIntervalMin(expected, gelGrams);
    if (interval != null) {
      rules.add(AlertRule(
          id: newRuleId(),
          trigger: TriggerKind.everyTime,
          value: interval * 60.0,
          message: 'Fuel time. Take ${gelGrams.round()} grams of carbs.',
          category: 'carb',
          cooldownSec: 60,
          priority: 3));
    } else if (expected.inMinutes >= 45 && expected.inMinutes < 75) {
      rules.add(AlertRule(
          id: newRuleId(),
          trigger: TriggerKind.atTime,
          value: expected.inSeconds * 0.5,
          message: 'Halfway. A small sip of sports drink or a mouth rinse can help.',
          category: 'carb',
          priority: 3));
    }
  }
  if (water && expected.inMinutes >= 45) {
    final w = waterPlan(expected: expected, sweatRateLph: sweatRateLph, hotDay: hotDay);
    final drink = w.electrolytes ? 'electrolyte drink' : 'water';
    rules.add(AlertRule(
        id: newRuleId(),
        trigger: TriggerKind.everyTime,
        value: w.intervalMin * 60.0,
        message: 'Drink about ${w.sipMl} millilitres of $drink, or drink to thirst.',
        category: 'water',
        cooldownSec: 60,
        priority: 3));
  }
  if (distanceM >= 3000) {
    rules.add(AlertRule(
        id: newRuleId(),
        trigger: TriggerKind.segmentStart,
        segment: segs.length - 1,
        message: 'Final stretch, you can push now if you feel good.',
        priority: 4));
  }

  final ultra = expected.inMinutes > 240;
  final km = (distanceM / 1000).toStringAsFixed(distanceM % 1000 == 0 ? 0 : 1);
  return AlertPlan(
    name: '$km km${goalTime != null ? ' in ${fmtDuration(goalTime)}' : ''}',
    kind: SessionKind.run,
    axis: PlanAxis.distance,
    distanceM: distanceM,
    goalTime: goalTime,
    segments: segs,
    rules: rules,
    ultra: ultra,
    builtIns: {
      for (final b in BuiltIn.values)
        b: ultra
            ? {BuiltIn.split, BuiltIn.sensor, BuiltIn.safety, BuiltIn.flatline, BuiltIn.hrHigh}.contains(b)
            : !{BuiltIn.timeInZone, BuiltIn.recovered, BuiltIn.intervals, BuiltIn.calories}.contains(b),
    },
  );
}

const hrActivities = ['Gym', 'Indoor cycling', 'Treadmill', 'HIIT', 'Yoga', 'Free monitoring'];

/// Default HR-only plan for an activity.
AlertPlan suggestHrPlan({
  required String activity,
  Duration? timeGoal,
  ({int zone, int minutes})? timeInZone,
  IntervalTimer? intervals,
}) {
  final (lo, hi) = switch (activity) {
    'Yoga' => (1, 2),
    'Free monitoring' => (1, 2),
    'HIIT' => (3, 5),
    'Gym' => (2, 4),
    _ => (2, 3),
  };
  final len = (timeGoal ?? const Duration(hours: 3)).inSeconds.toDouble();
  final zone = timeInZone?.zone;
  return AlertPlan(
    name: activity,
    kind: SessionKind.hrOnly,
    axis: PlanAxis.time,
    goalTime: timeGoal,
    activity: activity,
    timeInZoneGoal: timeInZone,
    intervals: intervals,
    segments: [
      Segment(name: activity, start: 0, end: len, zoneLow: zone ?? lo, zoneHigh: zone ?? hi),
    ],
    rules: [
      if (timeGoal != null)
        AlertRule(
            id: newRuleId(),
            trigger: TriggerKind.atTime,
            value: timeGoal.inSeconds.toDouble(),
            message: 'Time goal reached. Nice work.',
            priority: 3),
    ],
    builtIns: {
      for (final b in BuiltIn.values)
        b: switch (b) {
          BuiltIn.split || BuiltIn.projection || BuiltIn.drift || BuiltIn.finalPush || BuiltIn.sustainability => false,
          BuiltIn.hrLow => activity != 'Free monitoring' && activity != 'Gym' && activity != 'HIIT',
          BuiltIn.zoneChange => activity != 'Free monitoring',
          BuiltIn.timeInZone => timeInZone != null,
          BuiltIn.recovered => activity == 'Gym' || activity == 'HIIT',
          BuiltIn.intervals => intervals != null,
          _ => true,
        },
    },
  );
}

String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return '$m:${s.toString().padLeft(2, '0')}';
}

String fmtPace(double? secPerKm, {bool metric = true}) {
  if (secPerKm == null || secPerKm.isNaN || secPerKm.isInfinite || secPerKm <= 0 || secPerKm > 3600) return '--:--';
  final v = metric ? secPerKm : secPerKm * 1.609344;
  final m = v ~/ 60;
  final s = (v % 60).round();
  if (s == 60) return '${m + 1}:00';
  return '$m:${s.toString().padLeft(2, '0')}';
}

String fmtDistance(double m, {bool metric = true, int digits = 2}) =>
    metric ? (m / 1000).toStringAsFixed(digits) : (m / 1609.344).toStringAsFixed(digits);

String unitName(bool metric) => metric ? 'km' : 'mi';
