import 'dart:collection';
import 'dart:math' as math;

import 'plan.dart';
import 'zones.dart';

/// One second of session state, fed to the coach by the session controller.
class CoachInput {
  CoachInput({
    required this.t,
    required this.moving,
    required this.rawBpm,
    required this.contactOk,
    required this.secondsSinceReading,
    this.distanceM,
    this.isMoving = true,
    this.battery,
    this.kcal = 0,
  });

  /// Wall-clock seconds since the session started.
  final double t;

  /// Moving seconds (auto-pause excluded).
  final double moving;

  /// Latest BPM when fresh, null during a dropout.
  final double? rawBpm;
  final bool contactOk;
  final double secondsSinceReading;
  final double? distanceM;
  final bool isMoving;
  final int? battery;
  final double kcal;
}

class CoachEvent {
  CoachEvent({
    required this.key,
    required this.label,
    required this.message,
    required this.priority,
    this.delivery = RuleDelivery.voice,
    this.category = 'coach',
    this.safety = false,
  });

  /// BuiltIn name or rule id, used for cooldowns and muting.
  final String key;
  final String label;
  final String message;
  final int priority;
  final RuleDelivery delivery;
  final String category;
  final bool safety;
}

class SplitInfo {
  SplitInfo(this.index, this.seconds, this.avgHr, this.maxHr);
  final int index;
  final double seconds;
  final double? avgHr;
  final int? maxHr;
}

enum IntervalPhase { none, work, rest, done }

/// The in-run coach: smoothing, hysteresis, cooldowns, escalation and every
/// alert in the plan. Pure Dart so it can be tested without a phone.
class Coach {
  Coach({
    required this.plan,
    required this.zones,
    this.metric = true,
    this.defaultCooldown = 45,
  });

  final AlertPlan plan;
  final ZoneModel zones;
  final bool metric;
  final int defaultCooldown;

  final Set<String> muted = {};
  final Map<String, double> _lastFired = {};
  final Map<String, int> _count = {};

  final Queue<(double, double)> _window = Queue();
  double? smoothed;

  int? confirmedZone;
  int? _candidateZone;
  double? _candidateSince;

  int segIdx = -1;

  double? _aboveSince;
  double? _belowSince;
  double? _backInRangeSince;
  int _highStreak = 0;
  int _lowStreak = 0;
  double? _z4Since;
  double secondsInZone4Plus = 0;

  double? _lostSince;
  bool _signalLost = false;
  bool _batteryWarned = false;

  final Queue<int> _flat = Queue();

  final Queue<(double, double)> _trail = Queue(); // (moving, distance)
  double _nextSplit = 0;
  double _splitStartMoving = 0;
  double _splitHrSum = 0;
  int _splitHrN = 0;
  int _splitHrMax = 0;
  final List<SplitInfo> splits = [];
  double _nextProjection = 2000;
  bool _halfwayDone = false;
  bool _finalPushDone = false;

  double targetSeconds = 0;
  int _tizAnnounced = 0;
  bool _tizDone = false;

  bool _inEffort = false;
  double? _effortSince;
  int sets = 0;

  IntervalPhase phase = IntervalPhase.none;
  int round = 0;
  double _phaseStart = 0;

  int _kcalAnnounced = 0;
  final Map<String, double> _ruleSince = {};
  final Map<String, int> _ruleBucket = {};

  double? paceLastKm;
  double? currentPace;

  double get _splitUnit => metric ? 1000 : 1609.344;

  Segment? get segment => segIdx >= 0 && segIdx < plan.segments.length ? plan.segments[segIdx] : null;
  Segment? get nextSegment => segIdx + 1 < plan.segments.length ? plan.segments[segIdx + 1] : null;

  double _pos(CoachInput i) => plan.axis == PlanAxis.distance ? (i.distanceM ?? 0) : i.moving;

  void mute(String key) => muted.add(key);

  List<CoachEvent> tick(CoachInput i) {
    final out = <CoachEvent>[];
    if (_nextSplit == 0) _nextSplit = _splitUnit;
    _smooth(i);
    _trackPace(i);

    final newSeg = plan.segmentIndexAt(_pos(i));
    if (newSeg != segIdx) {
      final old = segIdx;
      segIdx = newSeg;
      if (old >= 0) _segmentChange(old, newSeg, i, out);
    }

    _sensor(i, out);
    if (plan.on(BuiltIn.intervals) && plan.intervals != null) _intervals(i, out);
    final s = smoothed;
    if (s != null) {
      _zone(s, i, out);
      _highLow(s, i, out);
      _flatline(i, out);
      _timeInZone(s, i, out);
      _recovered(s, i, out);
    }
    if (i.distanceM != null) {
      _splits(i, out);
      _projection(i, out);
      _finalPush(i, out);
    }
    _calories(i, out);
    _customRules(i, out);
    return out;
  }

  // ---------------------------------------------------------------------------

  bool _fire(
    List<CoachEvent> out,
    String key,
    String label,
    String message,
    int priority,
    double t, {
    int? cooldown,
    int? maxRepeats,
    RuleDelivery delivery = RuleDelivery.voice,
    String category = 'coach',
    bool safety = false,
    String? muteKey,
  }) {
    if (muted.contains(key) || (muteKey != null && muted.contains(muteKey))) return false;
    final cd = cooldown ?? defaultCooldown;
    final last = _lastFired[key];
    if (last != null && t - last < cd) return false;
    final n = _count[key] ?? 0;
    if (maxRepeats != null && n >= maxRepeats) return false;
    _lastFired[key] = t;
    _count[key] = n + 1;
    out.add(CoachEvent(
        key: key, label: label, message: message, priority: priority, delivery: delivery, category: category, safety: safety));
    return true;
  }

  bool _builtin(List<CoachEvent> out, BuiltIn b, String message, double t, {int? cooldown, bool safety = false}) {
    if (!plan.on(b)) return false;
    return _fire(out, b.name, b.label, message, b.priority, t,
        cooldown: plan.cooldown(b, cooldown ?? defaultCooldown), safety: safety || BuiltIn.safetyCritical.contains(b));
  }

  void _smooth(CoachInput i) {
    final b = i.rawBpm;
    if (b == null || !i.contactOk) {
      _window.clear();
      smoothed = null;
      return;
    }
    _window.addLast((i.t, b));
    while (_window.isNotEmpty && i.t - _window.first.$1 >= 5) {
      _window.removeFirst();
    }
    smoothed = _window.fold<double>(0, (a, e) => a + e.$2) / _window.length;
  }

  void _trackPace(CoachInput i) {
    final d = i.distanceM;
    if (d == null) return;
    _trail.addLast((i.moving, d));
    // Keep enough history for the last kilometre.
    while (_trail.length > 2 && d - _trail.elementAt(1).$2 >= 1000) {
      _trail.removeFirst();
    }
    if (d >= 1000) {
      final first = _trail.first;
      final span = d - first.$2;
      if (span > 0) paceLastKm = (i.moving - first.$1) / span * 1000;
    } else if (d > 50) {
      paceLastKm = i.moving / d * 1000;
    }
    // Current pace over roughly the last 30 moving seconds.
    (double, double)? ref;
    for (final p in _trail) {
      if (i.moving - p.$1 <= 30) {
        ref = p;
        break;
      }
    }
    if (ref != null && d - ref.$2 >= 20 && i.moving > ref.$1) {
      currentPace = (i.moving - ref.$1) / (d - ref.$2) * 1000;
    } else if (!i.isMoving) {
      currentPace = null;
    }
  }

  String _fill(String msg, CoachInput i) {
    final s = smoothed?.round();
    return msg
        .replaceAll('{bpm}', s?.toString() ?? '--')
        .replaceAll('{zone}', confirmedZone?.toString() ?? '--')
        .replaceAll('{distance}', i.distanceM == null ? '' : fmtDistance(i.distanceM!, metric: metric, digits: 1))
        .replaceAll('{time}', fmtDuration(Duration(seconds: i.moving.round())));
  }

  void _segmentChange(int old, int now, CoachInput i, List<CoachEvent> out) {
    for (final r in plan.rules) {
      if (!r.enabled) continue;
      if (r.trigger == TriggerKind.segmentEnd && (r.segment == null || r.segment == old)) {
        _fire(out, r.id, 'Custom', _fill(r.message, i), r.priority, i.t,
            cooldown: 0, maxRepeats: r.maxRepeats, delivery: r.delivery, category: r.category);
      }
      if (r.trigger == TriggerKind.segmentStart && (r.segment == null || r.segment == now)) {
        _fire(out, r.id, 'Custom', _fill(r.message, i), r.priority, i.t,
            cooldown: 0, maxRepeats: r.maxRepeats, delivery: r.delivery, category: r.category);
      }
    }
    final s = plan.segments[now];
    final zoneText = s.zoneLow == s.zoneHigh ? 'zone ${s.zoneLow}' : 'zones ${s.zoneLow} to ${s.zoneHigh}';
    _fire(out, 'segment', 'Segment change', '${s.name}. Target $zoneText.', 4, i.t, cooldown: 0);
  }

  void _sensor(CoachInput i, List<CoachEvent> out) {
    final bad = i.rawBpm == null || !i.contactOk;
    if (bad) {
      _lostSince ??= i.t - (i.rawBpm == null ? i.secondsSinceReading : 0);
      if (i.t - _lostSince! >= 5) {
        final msg = i.contactOk ? 'Heart rate signal lost.' : 'Heart rate strap has lost skin contact.';
        _builtin(out, BuiltIn.sensor, msg, i.t);
        _signalLost = true;
      }
    } else {
      _lostSince = null;
      if (_signalLost) {
        _signalLost = false;
        if (plan.on(BuiltIn.sensor) && !muted.contains(BuiltIn.sensor.name)) {
          out.add(CoachEvent(key: 'sensor_back', label: 'Sensor', message: 'Heart rate signal back.', priority: 6));
        }
      }
    }
    final b = i.battery;
    if (b != null && b <= 15 && !_batteryWarned) {
      _batteryWarned = true;
      _fire(out, 'battery', 'Sensor battery', 'Heart rate sensor battery low, $b percent.', 2, i.t,
          cooldown: 0, muteKey: BuiltIn.sensor.name);
    }
  }

  void _zone(double s, CoachInput i, List<CoachEvent> out) {
    final raw = zones.zoneOf(s);
    if (confirmedZone == null) {
      if (_candidateZone != raw) {
        _candidateZone = raw;
        _candidateSince = i.t;
      } else if (i.t - _candidateSince! >= 10) {
        confirmedZone = raw;
      }
      return;
    }
    final cz = confirmedZone!;
    final lo = zones.lowBpm(cz) - 2;
    final hi = zones.highBpm(cz) + 2;
    final outside = (s < lo && cz > 0) || (s > hi && cz < 5);
    if (!outside || raw == cz) {
      _candidateZone = null;
      return;
    }
    if (_candidateZone != raw) {
      _candidateZone = raw;
      _candidateSince = i.t;
      return;
    }
    if (i.t - _candidateSince! < 10) return;

    final from = cz;
    confirmedZone = raw;
    _candidateZone = null;
    final seg = segment;
    final inTarget = seg != null && raw >= seg.zoneLow && raw <= seg.zoneHigh;
    final wasTarget = seg != null && from >= seg.zoneLow && from <= seg.zoneHigh;
    String msg;
    if (plan.kind == SessionKind.hrOnly && seg != null) {
      msg = inTarget && !wasTarget
          ? (raw == 0 ? 'Back in target.' : 'Back in zone $raw.')
          : (!inTarget && wasTarget ? 'Out of target, now zone $raw.' : 'Now in zone $raw.');
    } else {
      msg = raw == 0 ? 'Below zone 1.' : 'Now in zone $raw.';
    }
    _builtin(out, BuiltIn.zoneChange, msg, i.t, cooldown: 20);

    for (final r in plan.rules) {
      if (!r.enabled || !_ruleActive(r)) continue;
      final hit = (r.trigger == TriggerKind.enterZone && r.zone == raw) ||
          (r.trigger == TriggerKind.leaveZone && r.zone == from);
      if (hit) {
        _fire(out, r.id, 'Custom', _fill(r.message, i), r.priority, i.t,
            cooldown: r.cooldownSec, maxRepeats: r.maxRepeats, delivery: r.delivery, category: r.category);
      }
    }
  }

  void _highLow(double s, CoachInput i, List<CoachEvent> out) {
    final seg = segment;
    if (seg == null) return;
    final ceil = seg.ceilingBpm(zones);
    final floor = seg.floorBpm(zones);
    final bpm = s.round();
    final run = plan.kind == SessionKind.run;
    final goalKm = plan.distanceM == null ? null : fmtDistance(plan.distanceM!, metric: metric, digits: plan.distanceM! % 1000 == 0 ? 0 : 1);

    if (zones.zoneOf(s) >= 4) {
      _z4Since ??= i.t;
      secondsInZone4Plus += 1;
    } else {
      _z4Since = null;
    }

    if (s > ceil) {
      _aboveSince ??= i.t;
      _backInRangeSince = null;
      final held = i.t - _aboveSince!;
      if (held >= 10) {
        final escalate = _highStreak >= 3;
        final msg = run && goalKm != null
            ? 'Heart rate $bpm, ease off. Slow down to hold $goalKm ${unitName(metric)}.'
            : 'Heart rate $bpm, ${run ? 'ease off' : 'slow down'}.';
        if (_builtin(out, BuiltIn.hrHigh, msg, i.t, cooldown: escalate ? 600 : null)) _highStreak++;
      }
      // Sustainability: hard effort with much of a longer run left.
      final d = i.distanceM;
      final goal = plan.distanceM;
      if (run && d != null && goal != null && goal > 5000 && (goal - d) / goal > 0.4 && zones.zoneOf(s) >= 4 &&
          _z4Since != null && i.t - _z4Since! >= 60) {
        _builtin(out, BuiltIn.sustainability,
            'Heart rate is too high to hold for the distance left. Slow down or walk until it drops under $ceil.', i.t,
            cooldown: 900);
      }
      if (held >= 20 * 60) {
        _builtin(
            out,
            BuiltIn.safety,
            'You have been above your ceiling for ${(held / 60).round()} minutes. Slow down, drink and eat. '
            'If you feel unwell, stop and get help.',
            i.t,
            cooldown: 1800);
      }
    } else {
      _aboveSince = null;
      if (s >= floor) {
        _backInRangeSince ??= i.t;
        if (i.t - _backInRangeSince! >= 60) {
          _highStreak = 0;
          _lowStreak = 0;
        }
      }
    }
    if (secondsInZone4Plus >= 2 * 3600 && run) {
      _builtin(out, BuiltIn.safety,
          'Two hours in zone 4 or higher. Slow down, drink and eat. If you feel unwell, stop and get help.', i.t,
          cooldown: 1800);
    }

    final restPhase = phase == IntervalPhase.rest;
    final grace = i.moving < 180;
    if (s < floor && !restPhase && !grace && (!run || i.isMoving)) {
      _belowSince ??= i.t;
      if (i.t - _belowSince! >= 20) {
        final escalate = _lowStreak >= 3;
        final msg = run ? 'Heart rate $bpm, you can push a little.' : 'Heart rate $bpm, below your target.';
        if (_builtin(out, BuiltIn.hrLow, msg, i.t, cooldown: escalate ? 600 : null)) _lowStreak++;
      }
    } else {
      _belowSince = null;
    }
  }

  void _flatline(CoachInput i, List<CoachEvent> out) {
    final b = i.rawBpm;
    if (b == null) {
      _flat.clear();
      return;
    }
    _flat.addLast(b.round());
    while (_flat.length > 600) {
      _flat.removeFirst();
    }
    if (_flat.length < 600) return;
    final mx = _flat.reduce(math.max);
    final mn = _flat.reduce(math.min);
    if (mx - mn < 3) {
      _builtin(out, BuiltIn.flatline, 'Heart rate has stayed at exactly ${b.round()}. Check the strap.', i.t,
          cooldown: 600);
    }
  }

  void _timeInZone(double s, CoachInput i, List<CoachEvent> out) {
    final seg = segment;
    if (seg == null) return;
    final z = zones.zoneOf(s);
    final goal = plan.timeInZoneGoal;
    final inTarget = goal != null ? z == goal.zone : (z >= seg.zoneLow && z <= seg.zoneHigh);
    if (inTarget) targetSeconds += 1;
    if (goal == null || _tizDone) return;
    final mins = targetSeconds ~/ 60;
    if (mins >= goal.minutes) {
      _tizDone = true;
      _builtin(out, BuiltIn.timeInZone, 'Goal met: ${goal.minutes} minutes in zone ${goal.zone}.', i.t, cooldown: 0);
    } else if (mins >= _tizAnnounced + 5 && mins % 5 == 0) {
      _tizAnnounced = mins;
      _builtin(out, BuiltIn.timeInZone, '$mins of ${goal.minutes} minutes in zone ${goal.zone} done.', i.t, cooldown: 0);
    }
  }

  void _recovered(double s, CoachInput i, List<CoachEvent> out) {
    final level = zones.recoveryLevel;
    if (s > level + 10) {
      _effortSince ??= i.t;
      if (i.t - _effortSince! >= 20) _inEffort = true;
    } else {
      _effortSince = null;
    }
    if (_inEffort && s <= level) {
      _inEffort = false;
      sets++;
      if (phase != IntervalPhase.rest || !(plan.intervals?.endRestOnRecovery ?? false)) {
        _builtin(out, BuiltIn.recovered, 'Recovered to ${s.round()}. Start your next set.', i.t, cooldown: 30);
      }
    }
  }

  void _intervals(CoachInput i, List<CoachEvent> out) {
    final it = plan.intervals!;
    if (phase == IntervalPhase.done) return;
    if (phase == IntervalPhase.none) {
      phase = IntervalPhase.work;
      round = 1;
      _phaseStart = i.t;
      _fire(out, 'interval_work', 'Interval timer', 'Work, round 1 of ${it.rounds}. Go.', 2, i.t, cooldown: 0, muteKey: BuiltIn.intervals.name);
      return;
    }
    final inPhase = i.t - _phaseStart;
    if (phase == IntervalPhase.work && inPhase >= it.workSec) {
      if (round >= it.rounds) {
        phase = IntervalPhase.done;
        _fire(out, 'interval_done', 'Interval timer', 'Intervals done. Easy now.', 2, i.t, cooldown: 0, muteKey: BuiltIn.intervals.name);
      } else {
        phase = IntervalPhase.rest;
        _phaseStart = i.t;
        _fire(out, 'interval_rest', 'Interval timer', 'Rest.', 2, i.t, cooldown: 0, muteKey: BuiltIn.intervals.name);
      }
    } else if (phase == IntervalPhase.rest) {
      final recovered = it.endRestOnRecovery && inPhase >= 15 && smoothed != null && smoothed! <= zones.recoveryLevel;
      if (inPhase >= it.restSec || recovered) {
        phase = IntervalPhase.work;
        round++;
        _phaseStart = i.t;
        final why = recovered && inPhase < it.restSec ? 'Recovered. ' : '';
        _fire(out, 'interval_work', 'Interval timer', '${why}Rest over, go. Round $round of ${it.rounds}.', 2, i.t,
            cooldown: 0, muteKey: BuiltIn.intervals.name);
      }
    }
  }

  /// Seconds left in the current work or rest phase, for the live screen.
  double? phaseRemaining(double t) {
    final it = plan.intervals;
    if (it == null) return null;
    final len = switch (phase) {
      IntervalPhase.work => it.workSec,
      IntervalPhase.rest => it.restSec,
      _ => null,
    };
    if (len == null) return null;
    return math.max(0, len - (t - _phaseStart));
  }

  void _splits(CoachInput i, List<CoachEvent> out) {
    final d = i.distanceM!;
    if (smoothed != null) {
      _splitHrSum += smoothed!;
      _splitHrN++;
      _splitHrMax = math.max(_splitHrMax, smoothed!.round());
    }
    if (d < _nextSplit) return;
    final idx = (_nextSplit / _splitUnit).round();
    final secs = i.moving - _splitStartMoving;
    final avg = _splitHrN > 0 ? _splitHrSum / _splitHrN : null;
    splits.add(SplitInfo(idx, secs, avg, _splitHrN > 0 ? _splitHrMax : null));
    _splitStartMoving = i.moving;
    _splitHrSum = 0;
    _splitHrN = 0;
    _splitHrMax = 0;
    _nextSplit += _splitUnit;

    final unitWord = metric ? 'Kilometre' : 'Mile';
    final pace = fmtPace(secs / (_splitUnit / 1000), metric: metric);
    var msg = '$unitWord $idx, ${_spokenPace(pace)} pace';
    if (avg != null) msg += ', average heart rate ${avg.round()}';
    if (plan.kcalWithSplit && i.kcal >= 1) msg += ', ${i.kcal.round()} kcal so far';
    _builtin(out, BuiltIn.split, '$msg.', i.t, cooldown: 0);

    // Drift: compare against kilometre 2 at a similar pace.
    if (splits.length >= 3) {
      final base = splits[1];
      final cur = splits.last;
      if (base.avgHr != null && cur.avgHr != null && base.seconds > 0) {
        final paceDiff = (cur.seconds - base.seconds).abs() / base.seconds;
        final hrRise = (cur.avgHr! - base.avgHr!) / base.avgHr!;
        if (paceDiff < 0.05 && hrRise > 0.05) {
          _builtin(out, BuiltIn.drift,
              'Heart rate rising at the same pace, slow 10 seconds per ${metric ? 'kilometre' : 'mile'}.', i.t,
              cooldown: 1200);
        }
      }
    }
  }

  String _spokenPace(String p) {
    final parts = p.split(':');
    if (parts.length != 2) return p;
    return '${parts[0]} ${parts[1]}';
  }

  void _projection(CoachInput i, List<CoachEvent> out) {
    final goal = plan.distanceM;
    final d = i.distanceM!;
    if (goal == null || goal <= 0) return;
    var due = false;
    if (!_halfwayDone && d >= goal / 2) {
      _halfwayDone = true;
      due = true;
    }
    if (d >= _nextProjection) {
      while (_nextProjection <= d) {
        _nextProjection += 2000;
      }
      due = true;
    }
    if (!due || d >= goal) return;
    final pace = paceLastKm;
    if (pace == null) return;
    final projected = i.moving + (goal - d) / 1000 * pace;
    final pStr = _spokenTime(projected);
    String msg;
    final gt = plan.goalTime;
    if (gt != null) {
      final diff = projected - gt.inSeconds;
      if (diff > 30) {
        msg = 'Projected $pStr, ${_spokenTime(diff)} behind target. Speed up a little.';
      } else if (diff < -30) {
        msg = 'Projected $pStr, ahead of target.';
      } else {
        msg = 'On track for $pStr.';
      }
    } else {
      msg = 'Projected finish $pStr.';
    }
    final seg = segment;
    if (seg != null && confirmedZone != null) {
      msg += confirmedZone! <= seg.zoneHigh ? ' Heart rate is sustainable.' : ' Pace is fine but the effort is high.';
    }
    _builtin(out, BuiltIn.projection, msg, i.t, cooldown: 0);
  }

  String _spokenTime(double secs) {
    final d = Duration(seconds: secs.round());
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '$h hours $m minutes';
    if (m > 0) return '$m minutes ${s > 0 ? '$s seconds' : ''}'.trim();
    return '$s seconds';
  }

  void _finalPush(CoachInput i, List<CoachEvent> out) {
    final goal = plan.distanceM;
    if (goal == null || _finalPushDone) return;
    final d = i.distanceM!;
    if (d < goal * 0.9 || d >= goal) return;
    final s = smoothed;
    final seg = segment;
    if (s == null || seg == null) return;
    if (s < seg.ceilingBpm(zones) - 5) {
      _finalPushDone = true;
      final left = ((goal - d) / 100).round() * 100;
      final leftText = metric
          ? (left >= 1000 ? '${(left / 1000).toStringAsFixed(1)} kilometres' : '$left metres')
          : '${(left / 1609.344).toStringAsFixed(1)} miles';
      _builtin(out, BuiltIn.finalPush, 'Last $leftText, you have room to push.', i.t, cooldown: 0);
    }
  }

  void _calories(CoachInput i, List<CoachEvent> out) {
    final hundreds = i.kcal ~/ 100;
    if (hundreds > _kcalAnnounced) {
      _kcalAnnounced = hundreds;
      _builtin(out, BuiltIn.calories, '${hundreds * 100} kcal so far.', i.t, cooldown: 0);
    }
  }

  bool _ruleActive(AlertRule r) => r.segment == null || r.segment == segIdx;

  void _customRules(CoachInput i, List<CoachEvent> out) {
    for (final r in plan.rules) {
      if (!r.enabled || !_ruleActive(r)) continue;
      bool hit = false;
      switch (r.trigger) {
        case TriggerKind.atDistance:
          final d = i.distanceM;
          hit = d != null && d >= r.value && (_count[r.id] ?? 0) == 0;
        case TriggerKind.atTime:
          hit = i.moving >= r.value && (_count[r.id] ?? 0) == 0;
        case TriggerKind.everyDistance:
          final d = i.distanceM;
          if (d != null && r.value > 0) {
            final bucket = d ~/ r.value;
            final prev = _ruleBucket[r.id] ?? 0;
            if (bucket > prev) {
              _ruleBucket[r.id] = bucket;
              hit = true;
            }
          }
        case TriggerKind.everyTime:
          if (r.value > 0) {
            final bucket = i.moving ~/ r.value;
            final prev = _ruleBucket[r.id] ?? 0;
            if (bucket > prev) {
              _ruleBucket[r.id] = bucket;
              hit = true;
            }
          }
        case TriggerKind.hrAbove:
        case TriggerKind.hrBelow:
          final s = smoothed;
          final cond = s != null && (r.trigger == TriggerKind.hrAbove ? s > r.value : s < r.value);
          hit = _held(r, cond, i.t);
        case TriggerKind.paceFaster:
        case TriggerKind.paceSlower:
          final p = currentPace;
          final cond = i.isMoving && p != null && (r.trigger == TriggerKind.paceFaster ? p < r.value : p > r.value);
          hit = _held(r, cond, i.t);
        case TriggerKind.enterZone:
        case TriggerKind.leaveZone:
        case TriggerKind.segmentStart:
        case TriggerKind.segmentEnd:
          break;
      }
      if (hit) {
        final cd = switch (r.trigger) {
          TriggerKind.atDistance || TriggerKind.atTime || TriggerKind.everyDistance || TriggerKind.everyTime => 0,
          _ => r.cooldownSec,
        };
        _fire(out, r.id, r.category == 'custom' ? 'Custom' : r.category, _fill(r.message, i), r.priority, i.t,
            cooldown: cd, maxRepeats: r.maxRepeats, delivery: r.delivery, category: r.category);
      }
    }
  }

  bool _held(AlertRule r, bool cond, double t) {
    if (!cond) {
      _ruleSince.remove(r.id);
      return false;
    }
    final since = _ruleSince.putIfAbsent(r.id, () => t);
    return t - since >= r.holdSec;
  }
}

/// What actually gets spoken: the highest-priority voice event, with a
/// second one merged in.
class Utterance {
  Utterance(this.text, this.safety, this.events);
  final String text;
  final bool safety;
  final List<CoachEvent> events;
}

Utterance? mergeEvents(List<CoachEvent> events) {
  final spoken = events.where((e) => e.delivery == RuleDelivery.voice).toList()
    ..sort((a, b) => a.priority.compareTo(b.priority));
  if (spoken.isEmpty) return null;
  final parts = spoken.take(2).map((e) => e.message).toList();
  return Utterance(parts.join(' '), spoken.any((e) => e.safety), spoken);
}

/// Where alerts are expected to fire on a run at goal pace, for the planner
/// preview. Only position-based alerts can be predicted.
List<(double pos, String label)> previewAlerts(AlertPlan plan, {bool metric = true}) {
  final res = <(double, String)>[];
  final total = plan.axis == PlanAxis.distance ? (plan.distanceM ?? 0) : (plan.goalTime?.inSeconds.toDouble() ?? 3600);
  if (total <= 0) return res;
  final pace = plan.goalTime != null && plan.distanceM != null && plan.distanceM! > 0
      ? plan.goalTime!.inSeconds / plan.distanceM! // seconds per metre
      : 0.36;
  double toPos(double seconds) => plan.axis == PlanAxis.distance ? seconds / pace : seconds;
  final unit = metric ? 1000.0 : 1609.344;
  if (plan.axis == PlanAxis.distance && plan.on(BuiltIn.split)) {
    for (var d = unit; d < total; d += unit) {
      res.add((d, 'Split'));
    }
  }
  if (plan.axis == PlanAxis.distance && plan.on(BuiltIn.projection)) {
    for (var d = 2000.0; d < total; d += 2000) {
      res.add((d, 'Projection'));
    }
    res.add((total / 2, 'Halfway projection'));
  }
  for (var i = 1; i < plan.segments.length; i++) {
    res.add((plan.segments[i].start, 'Start ${plan.segments[i].name}'));
  }
  for (final r in plan.rules.where((r) => r.enabled)) {
    final label = r.message.length > 28 ? '${r.message.substring(0, 28)}…' : r.message;
    switch (r.trigger) {
      case TriggerKind.atDistance:
        if (plan.axis == PlanAxis.distance) res.add((r.value, label));
      case TriggerKind.atTime:
        res.add((toPos(r.value), label));
      case TriggerKind.everyDistance:
        if (plan.axis == PlanAxis.distance && r.value > 0) {
          for (var d = r.value; d < total; d += r.value) {
            res.add((d, label));
          }
        }
      case TriggerKind.everyTime:
        if (r.value > 0) {
          for (var t = r.value; toPos(t) < total; t += r.value) {
            res.add((toPos(t), label));
          }
        }
      default:
        break;
    }
  }
  res.sort((a, b) => a.$1.compareTo(b.$1));
  return res.where((e) => e.$1 <= total).toList();
}
