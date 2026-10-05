import 'dart:math' as math;

import 'formulas.dart';
import 'models.dart';
import 'plan.dart';
import 'profile.dart';
import 'zones.dart';

const bestEffortDistances = {
  '1 km': 1000.0,
  '5 km': 5000.0,
  '10 km': 10000.0,
  'Half marathon': 21097.5,
  'Marathon': 42195.0,
};

/// Computes everything the summary screens show, once, when the session
/// ends. The result is cached as JSON on the session row.
Map<String, dynamic> computeSummary(SessionData data, Profile profile) {
  final s = data.session;
  final zones = profile.zones;
  final plan = s.plan;
  final metric = profile.metric;
  final res = <String, dynamic>{};

  final elapsed = (s.end ?? DateTime.now()).difference(s.start).inMilliseconds / 1000;
  final moving = s.movingS > 0 ? s.movingS : elapsed;
  res['elapsedS'] = elapsed;
  res['movingS'] = moving;

  // --- Heart rate, with flat-lined stretches greyed out of the stats.
  final hr = data.hr;
  final excluded = flatlineMask(hr);
  res['flatlineS'] = excluded.where((e) => e).length;
  final valid = <int>[];
  for (var i = 0; i < hr.length; i++) {
    final h = hr[i];
    if (h.contact && h.bpm >= 30 && h.bpm <= 230 && !excluded[i]) valid.add(i);
  }
  double dtAt(int i) {
    if (i + 1 >= hr.length) return 1;
    return ((hr[i + 1].tMs - hr[i].tMs) / 1000).clamp(0, 5).toDouble();
  }

  final timeInZones = List<double>.filled(6, 0);
  var hrSum = 0.0;
  var hrWeight = 0.0;
  var maxHr = 0;
  var trimp = 0.0;
  var beats = 0.0;
  var kcal = 0.0;
  final assumedRest = profile.restingHr == null;
  final trimpZones = ZoneModel(maxHr: zones.maxHr, restHr: profile.restingHr ?? 60);
  for (final i in valid) {
    final h = hr[i];
    final dt = dtAt(i);
    timeInZones[zones.zoneOf(h.bpm)] += dt;
    hrSum += h.bpm * dt;
    hrWeight += dt;
    maxHr = math.max(maxHr, h.bpm);
    trimp += trimpSlice(minutes: dt / 60, hrr: trimpZones.fraction(h.bpm), sex: profile.sex);
    beats += h.bpm * dt / 60;
    if (profile.canEstimateCalories) {
      kcal += keytelKcalPerMin(bpm: h.bpm.toDouble(), age: profile.age!, weightKg: profile.weightKg!, sex: profile.sex) *
          dt /
          60;
    }
  }
  final avgHr = hrWeight > 0 ? hrSum / hrWeight : null;
  res['avgHr'] = avgHr;
  res['maxHr'] = maxHr > 0 ? maxHr : null;
  res['timeInZones'] = timeInZones;
  res['trimp'] = trimp;
  res['trimpAssumedRest'] = assumedRest;
  res['kcal'] = profile.canEstimateCalories ? kcal : null;

  // --- Distance and pace.
  final gps = data.gps;
  final distance = s.manualDistanceM ?? (gps.isNotEmpty ? gps.last.dist : 0.0);
  res['distanceM'] = distance;
  res['avgPace'] = distance > 50 ? moving / distance * 1000 : null;

  // Calories cross-check from GPS (ACSM running equation).
  if (profile.weightKg != null && gps.length > 2 && s.kind == SessionKind.run) {
    var k = 0.0;
    for (var i = 1; i < gps.length; i++) {
      final a = gps[i - 1], b = gps[i];
      final dt = (b.tMs - a.tMs) / 1000;
      final dd = b.dist - a.dist;
      if (dt <= 0 || dt > 30 || !b.moving) continue;
      final grade = (a.alt != null && b.alt != null && dd > 1) ? ((b.alt! - a.alt!) / dd).clamp(-0.3, 0.3) : 0.0;
      k += acsmRunningKcalPerMin(speedMps: dd / dt, grade: grade, weightKg: profile.weightKg!) * dt / 60;
    }
    res['kcalGps'] = k;
    if (profile.canEstimateCalories && kcal > 0 && k > 0) {
      final diff = (kcal - k).abs() / math.max(kcal, k);
      if (diff > 0.25) res['kcalRange'] = [math.min(kcal, k), math.max(kcal, k)];
    }
  }

  // --- Splits.
  final unit = metric ? 1000.0 : 1609.344;
  final splits = <Map<String, dynamic>>[];
  if (gps.length > 1 && distance >= unit * 0.5) {
    var nextMark = unit;
    var prevT = gps.first.tMs.toDouble();
    double? prevAlt = gps.first.alt;
    var idx = 1;
    for (var i = 1; i < gps.length; i++) {
      final a = gps[i - 1], b = gps[i];
      while (b.dist >= nextMark && a.dist < nextMark) {
        final f = b.dist == a.dist ? 0.0 : (nextMark - a.dist) / (b.dist - a.dist);
        final t = a.tMs + f * (b.tMs - a.tMs);
        splits.add(_split(idx, prevT, t, hr, prevAlt, b.alt, moving: _movingBetween(gps, prevT, t)));
        prevT = t;
        prevAlt = b.alt;
        idx++;
        nextMark += unit;
      }
    }
    final lastDist = gps.last.dist - (nextMark - unit);
    if (lastDist > 50) {
      final sp = _split(idx, prevT, gps.last.tMs.toDouble(), hr, prevAlt, gps.last.alt,
          moving: _movingBetween(gps, prevT, gps.last.tMs.toDouble()));
      sp['partialM'] = lastDist;
      sp['pace'] = (sp['seconds'] as double) / lastDist * 1000;
      splits.add(sp);
    }
  }
  res['splits'] = splits;
  final full = splits.where((x) => x['partialM'] == null).toList();
  if (full.isNotEmpty) {
    full.sort((a, b) => (a['seconds'] as double).compareTo(b['seconds'] as double));
    res['fastestSplit'] = full.first['index'];
    final withHr = full.where((x) => x['avgHr'] != null).toList()
      ..sort((a, b) => (b['avgHr'] as double).compareTo(a['avgHr'] as double));
    if (withHr.isNotEmpty) res['hardestSplit'] = withHr.first['index'];
  }

  // --- Drift: pace-to-HR decoupling between the halves (after the first 10%).
  if (valid.length > 600) {
    final startT = hr[valid[(valid.length * 0.1).floor()]].tMs;
    final endT = hr[valid.last].tMs;
    final mid = (startT + endT) / 2;
    double avgBetween(int a, double b) {
      var sum = 0.0, n = 0;
      for (final i in valid) {
        final t = hr[i].tMs;
        if (t >= a && t < b) {
          sum += hr[i].bpm;
          n++;
        }
      }
      return n == 0 ? 0 : sum / n;
    }

    final h1 = avgBetween(startT, mid);
    final h2 = avgBetween(mid.round(), endT + 1.0);
    if (h1 > 0 && h2 > 0) {
      if (s.kind == SessionKind.run && gps.length > 10) {
        final d1 = _distAt(gps, mid) - _distAt(gps, startT.toDouble());
        final d2 = _distAt(gps, endT.toDouble()) - _distAt(gps, mid);
        if (d1 > 100 && d2 > 100) {
          final e1 = d1 / h1, e2 = d2 / h2;
          res['driftPct'] = (e1 - e2) / e1 * 100;
          res['driftKind'] = 'decoupling';
        }
      } else {
        res['driftPct'] = (h2 - h1) / h1 * 100;
        res['driftKind'] = 'hr';
      }
    }
  }

  // --- Efficiency.
  if (beats > 0 && distance > 100) {
    res['metresPerBeat'] = distance / beats;
    if (avgHr != null && moving > 0) res['efficiency'] = (distance / moving * 60) / avgHr; // m/min per bpm
  }
  if (s.manualWatts != null && avgHr != null) res['wattsPerBeat'] = s.manualWatts! / avgHr;

  // --- Recovery after the session.
  if (s.recoveryStartBpm != null && s.recoveryEndBpm != null) {
    res['hrr60'] = s.recoveryStartBpm! - s.recoveryEndBpm!;
  }

  // --- HRV.
  final rv = rmssd(data.rr.map((e) => e.rr).toList());
  res['rmssd'] = rv;
  res['rrAvailable'] = data.rr.isNotEmpty;

  // --- Effort blocks (sets or intervals).
  res['efforts'] = effortBlocks(hr, zones.recoveryLevel, excluded);

  // --- Plan adherence.
  if (plan != null && plan.segments.isNotEmpty && valid.isNotEmpty) {
    final inSeg = List<double>.filled(plan.segments.length, 0);
    final inTarget = List<double>.filled(plan.segments.length, 0);
    for (final i in valid) {
      final h = hr[i];
      final pos = plan.axis == PlanAxis.distance ? _distAt(gps, h.tMs.toDouble()) : h.tMs / 1000;
      final si = plan.segmentIndexAt(pos);
      if (si < 0) continue;
      final seg = plan.segments[si];
      final dt = dtAt(i);
      inSeg[si] += dt;
      if (h.bpm >= seg.floorBpm(zones) && h.bpm <= seg.ceilingBpm(zones)) inTarget[si] += dt;
    }
    res['adherence'] = [
      for (var i = 0; i < plan.segments.length; i++)
        {
          'name': plan.segments[i].name,
          'seconds': inSeg[i],
          'pct': inSeg[i] > 0 ? inTarget[i] / inSeg[i] * 100 : null,
        }
    ];
    final totalSeg = inSeg.fold<double>(0, (a, b) => a + b);
    res['targetPct'] = totalSeg > 0 ? inTarget.fold<double>(0, (a, b) => a + b) / totalSeg * 100 : null;
  }

  // --- Alerts.
  final counts = <String, int>{};
  for (final a in data.alerts) {
    counts[a.type] = (counts[a.type] ?? 0) + 1;
  }
  res['alertCounts'] = counts;
  res['muted'] = s.muted;

  // --- Fuel.
  final carbs = data.intake.where((e) => e.kind == 'carb').fold<double>(0, (a, e) => a + e.amount);
  final water = data.intake.where((e) => e.kind == 'water').fold<double>(0, (a, e) => a + e.amount);
  res['carbsG'] = carbs;
  res['waterMl'] = water;
  res['carbsPerHour'] = moving > 0 ? carbs / (moving / 3600) : 0;

  // --- Best efforts.
  if (gps.length > 2 && s.kind == SessionKind.run) {
    final best = <String, double>{};
    for (final e in bestEffortDistances.entries) {
      if (distance < e.value) continue;
      final t = bestEffort(gps, e.value);
      if (t != null) best[e.key] = t;
    }
    res['bestEfforts'] = best;
  }

  // --- Goal.
  if (s.goalDistanceM != null && s.goalDistanceM! > 0) {
    final distOk = distance >= s.goalDistanceM! * 0.98;
    final timeOk = s.goalTime == null || moving <= s.goalTime!.inSeconds;
    res['goalMet'] = distOk && timeOk;
  } else if (plan?.timeInZoneGoal != null) {
    final g = plan!.timeInZoneGoal!;
    res['goalMet'] = timeInZones[g.zone] >= g.minutes * 60;
  } else if (s.goalTime != null) {
    res['goalMet'] = moving >= s.goalTime!.inSeconds;
  }

  // --- Clean new max HR (held 30 s, contact good, no flat-line).
  final cleanMax = cleanPeak(hr, excluded);
  if (cleanMax != null && cleanMax > zones.maxHr) res['newMaxHr'] = cleanMax;

  res['takeaway'] = takeaway(res, plan, zones);
  res['deviceKind'] = s.deviceKind;
  return res;
}

Map<String, dynamic> _split(int idx, double t0, double t1, List<HrSample> hr, double? alt0, double? alt1,
    {required double moving}) {
  var sum = 0.0, n = 0, mx = 0;
  for (final h in hr) {
    if (h.tMs >= t0 && h.tMs < t1 && h.contact) {
      sum += h.bpm;
      n++;
      mx = math.max(mx, h.bpm);
    }
  }
  final secs = moving > 0 ? moving : (t1 - t0) / 1000;
  return {
    'index': idx,
    'seconds': secs,
    'pace': secs,
    'avgHr': n > 0 ? sum / n : null,
    'maxHr': n > 0 ? mx : null,
    'elev': alt0 != null && alt1 != null ? alt1 - alt0 : null,
  };
}

double _movingBetween(List<GpsPoint> gps, double t0, double t1) {
  var m = 0.0;
  for (var i = 1; i < gps.length; i++) {
    final a = gps[i - 1], b = gps[i];
    if (b.tMs <= t0 || a.tMs >= t1 || !b.moving) continue;
    final s = math.max(a.tMs.toDouble(), t0);
    final e = math.min(b.tMs.toDouble(), t1);
    if (e > s) m += (e - s) / 1000;
  }
  return m;
}

double _distAt(List<GpsPoint> gps, double tMs) {
  if (gps.isEmpty) return 0;
  if (tMs <= gps.first.tMs) return gps.first.dist;
  if (tMs >= gps.last.tMs) return gps.last.dist;
  var lo = 0, hi = gps.length - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) ~/ 2;
    if (gps[mid].tMs <= tMs) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final a = gps[lo], b = gps[hi];
  final f = b.tMs == a.tMs ? 0 : (tMs - a.tMs) / (b.tMs - a.tMs);
  return a.dist + f * (b.dist - a.dist);
}

/// Marks samples inside any 10-minute stretch whose spread is under 3 BPM.
List<bool> flatlineMask(List<HrSample> hr, {int windowS = 600}) {
  final mask = List<bool>.filled(hr.length, false);
  if (hr.length < windowS) return mask;
  var start = 0;
  for (var end = 0; end < hr.length; end++) {
    while (hr[end].tMs - hr[start].tMs > windowS * 1000) {
      start++;
    }
    if (hr[end].tMs - hr[start].tMs >= (windowS - 2) * 1000 && end - start + 1 >= windowS * 0.9) {
      var mn = 999, mx = 0;
      for (var k = start; k <= end; k++) {
        mn = math.min(mn, hr[k].bpm);
        mx = math.max(mx, hr[k].bpm);
      }
      if (mx - mn < 3) {
        for (var k = start; k <= end; k++) {
          mask[k] = true;
        }
      }
    }
  }
  return mask;
}

/// Highest BPM held for 30 s (the lowest value inside the best 30 s window),
/// with good contact and outside flat-lined stretches.
int? cleanPeak(List<HrSample> hr, List<bool> excluded) {
  int? best;
  var start = 0;
  for (var end = 0; end < hr.length; end++) {
    if (!hr[end].contact || excluded[end]) {
      start = end + 1;
      continue;
    }
    while (start < end && hr[end].tMs - hr[start].tMs > 30000) {
      start++;
    }
    if (hr[end].tMs - hr[start].tMs >= 29000 && end - start >= 25) {
      var mn = 999;
      for (var k = start; k <= end; k++) {
        mn = math.min(mn, hr[k].bpm);
      }
      if (best == null || mn > best) best = mn;
    }
  }
  return best;
}

/// Efforts: stretches where 10 s-smoothed HR stays above the recovery level
/// for at least 20 s. Recovery is the drop in the 60 s after each peak.
List<Map<String, dynamic>> effortBlocks(List<HrSample> hr, int level, List<bool> excluded) {
  final res = <Map<String, dynamic>>[];
  if (hr.length < 30) return res;
  final sm = <double>[];
  var sum = 0.0;
  for (var i = 0; i < hr.length; i++) {
    sum += hr[i].bpm;
    if (i >= 10) sum -= hr[i - 10].bpm;
    sm.add(sum / math.min(i + 1, 10));
  }
  int? start;
  for (var i = 0; i <= sm.length; i++) {
    final above = i < sm.length && sm[i] > level && !excluded[i];
    if (above) {
      start ??= i;
    } else if (start != null) {
      final dur = (hr[i - 1].tMs - hr[start].tMs) / 1000;
      if (dur >= 20) {
        var peakI = start;
        for (var k = start; k < i; k++) {
          if (hr[k].bpm > hr[peakI].bpm) peakI = k;
        }
        final peakT = hr[peakI].tMs;
        int? after;
        for (var k = peakI; k < hr.length; k++) {
          if (hr[k].tMs - peakT >= 60000) {
            after = hr[k].bpm;
            break;
          }
        }
        res.add({
          'startS': hr[start].tMs / 1000,
          'durationS': dur,
          'peak': hr[peakI].bpm,
          'recovery60': after == null ? null : hr[peakI].bpm - after,
        });
      }
      start = null;
    }
  }
  return res;
}

/// Fastest time (seconds) to cover [meters] anywhere in the run.
double? bestEffort(List<GpsPoint> gps, double meters) {
  double? best;
  var j = 0;
  for (var i = 0; i < gps.length; i++) {
    while (j < gps.length && gps[j].dist - gps[i].dist < meters) {
      j++;
    }
    if (j >= gps.length) break;
    final a = gps[j - 1], b = gps[j];
    final need = gps[i].dist + meters;
    final f = b.dist == a.dist ? 0 : (need - a.dist) / (b.dist - a.dist);
    final t = (a.tMs + f * (b.tMs - a.tMs) - gps[i].tMs) / 1000;
    if (best == null || t < best) best = t;
  }
  return best;
}

String takeaway(Map<String, dynamic> r, AlertPlan? plan, ZoneModel zones) {
  final parts = <String>[];
  final pct = r['targetPct'] as double?;
  final seg = plan?.segments.isNotEmpty == true ? plan!.segments[plan.segments.length > 2 ? 1 : 0] : null;
  final tz = r['timeInZones'] as List<double>;
  final total = tz.fold<double>(0, (a, b) => a + b);
  if ((r['flatlineS'] as int) > 300) {
    parts.add('Part of the heart rate looked stuck, so it was left out of the stats. Check the strap fit before next time.');
  }
  if (pct != null && seg != null) {
    final zoneText = seg.zoneLow == seg.zoneHigh ? 'zone ${seg.zoneLow}' : 'zones ${seg.zoneLow}–${seg.zoneHigh}';
    final above = total > 0 ? tz.sublist(math.min(seg.zoneHigh + 1, 6)).fold<double>(0, (a, b) => a + b) / total : 0;
    if (pct >= 80 && r['goalMet'] != false) {
      parts.add('You held your target ($zoneText) for ${pct.round()}% of the session; next time you can start 5 s/km faster.');
    } else if (above > 0.3) {
      parts.add('You spent ${(above * 100).round()}% above your target ($zoneText). Start slower next time.');
    } else {
      parts.add('You held your target ($zoneText) for ${pct.round()}% of the session.');
    }
  }
  final drift = r['driftPct'] as double?;
  if (drift != null && drift > 5) {
    parts.add('Heart rate drifted up ${drift.toStringAsFixed(0)}% relative to pace; drink earlier or ease off slightly in the second half.');
  }
  if (parts.isEmpty) {
    final avg = r['avgHr'] as double?;
    if (avg != null) {
      parts.add('Average heart rate ${avg.round()} BPM, mostly in zone ${zones.zoneOf(avg)}.');
    } else {
      parts.add('No heart rate was recorded for this session.');
    }
  }
  return parts.join(' ');
}
