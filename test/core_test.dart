import 'package:flutter_test/flutter_test.dart';
import 'package:zonestep/core/coach.dart';
import 'package:zonestep/core/formulas.dart';
import 'package:zonestep/core/hr_parser.dart';
import 'package:zonestep/core/models.dart';
import 'package:zonestep/core/plan.dart';
import 'package:zonestep/core/profile.dart';
import 'package:zonestep/core/stats.dart';
import 'package:zonestep/core/zones.dart';

void main() {
  group('heart rate parser', () {
    test('8-bit BPM without contact support', () {
      final r = parseHeartRate([0x00, 72])!;
      expect(r.bpm, 72);
      expect(r.contactSupported, false);
      expect(r.hasContact, true);
      expect(r.rrMs, isEmpty);
    });

    test('16-bit BPM with contact and RR', () {
      // flags: 16-bit, contact supported+detected, RR present
      final r = parseHeartRate([0x01 | 0x02 | 0x04 | 0x10, 0x2C, 0x01, 0x00, 0x04, 0x00, 0x02])!;
      expect(r.bpm, 300);
      expect(r.hasContact, true);
      expect(r.rrMs.length, 2);
      expect(r.rrMs[0], closeTo(1000, 0.01));
      expect(r.rrMs[1], closeTo(500, 0.01));
    });

    test('contact supported but lost', () {
      final r = parseHeartRate([0x04, 80])!;
      expect(r.hasContact, false);
    });

    test('energy field is skipped before RR', () {
      final r = parseHeartRate([0x08 | 0x10, 90, 0x10, 0x00, 0x00, 0x04])!;
      expect(r.energyKj, 16);
      expect(r.rrMs.single, closeTo(1000, 0.01));
    });

    test('truncated packet returns null', () {
      expect(parseHeartRate([0x01, 0x10]), isNull);
      expect(parseHeartRate([]), isNull);
    });
  });

  group('zones and max HR', () {
    test('Tanaka and cautious estimates', () {
      final p = Profile(age: 30);
      expect(p.maxHr, 187);
      p.cautious = true;
      expect(p.maxHr, 187); // 220-30 = 190 > 187
      p.age = 60;
      expect(p.maxHr, 160); // min(166, 160)
      p.maxHrValue = 175;
      expect(p.maxHr, 175);
    });

    test('Karvonen zones match the plan worked example', () {
      const z = ZoneModel(maxHr: 187, restHr: 60);
      expect(z.fraction(170), closeTo(0.866, 0.01));
      expect(z.zoneOf(170), 4);
      expect(z.highBpm(3), 161);
      expect(z.lowBpm(2), 136);
    });

    test('percent of max when no resting HR', () {
      const z = ZoneModel(maxHr: 200);
      expect(z.usesReserve, false);
      expect(z.zoneOf(99), 0);
      expect(z.zoneOf(100), 1);
      expect(z.zoneOf(185), 5);
    });
  });

  group('formulas', () {
    test('Keytel is positive and sex-specific', () {
      final m = keytelKcalPerMin(bpm: 150, age: 30, weightKg: 70, sex: Sex.male);
      final f = keytelKcalPerMin(bpm: 150, age: 30, weightKg: 70, sex: Sex.female);
      expect(m, closeTo(14.2, 0.1));
      expect(f, closeTo(9.6, 0.1));
      expect(keytelKcalPerMin(bpm: 40, age: 20, weightKg: 50, sex: Sex.male), 0);
    });

    test('carb interval from gel size', () {
      expect(carbIntervalMin(const Duration(minutes: 140), 25), 25);
      expect(carbIntervalMin(const Duration(minutes: 40), 25), isNull);
    });

    test('RMSSD rejects artefacts', () {
      final rr = List<double>.generate(100, (i) => i.isEven ? 800 : 820);
      expect(rmssd(rr), closeTo(20, 0.01));
      expect(rmssd([800, 810]), isNull);
    });

    test('sweat rate', () {
      expect(
          sweatRate(weightBeforeKg: 70, weightAfterKg: 69, drankL: 0.5, duration: const Duration(hours: 1)), 1.5);
    });
  });

  group('coach', () {
    const zones = ZoneModel(maxHr: 187, restHr: 60);

    List<CoachEvent> runFor(Coach c, int seconds, double Function(int t) bpm,
        {double Function(int t)? dist, int from = 0}) {
      final all = <CoachEvent>[];
      for (var t = from; t < from + seconds; t++) {
        all.addAll(c.tick(CoachInput(
          t: t.toDouble(),
          moving: t.toDouble(),
          rawBpm: bpm(t),
          contactOk: true,
          secondsSinceReading: 0,
          distanceM: dist?.call(t),
        )));
      }
      return all;
    }

    test('high BPM fires after 10 s and respects cooldown', () {
      final plan = suggestRunPlan(distanceM: 100000);
      final c = Coach(plan: plan, zones: zones);
      final ev = runFor(c, 300, (t) => t < 200 ? 140 : 175, dist: (t) => t * 2.5);
      final highs = ev.where((e) => e.key == 'hrHigh').toList();
      expect(highs, isNotEmpty);
      expect(highs.first.message, contains('ease off'));
      // 100 s above ceiling with 45 s cooldown: at most 3 alerts.
      expect(highs.length, lessThanOrEqualTo(3));
    });

    test('zone change needs 10 s plus buffer (no flapping)', () {
      final plan = suggestRunPlan(distanceM: 10000);
      final c = Coach(plan: plan, zones: zones);
      // Hover around the 3/4 boundary (161) for 2 minutes.
      final ev = runFor(c, 120, (t) => t.isEven ? 160 : 162, dist: (t) => t * 3.0);
      expect(ev.where((e) => e.key == 'zoneChange'), isEmpty);
    });

    test('splits and projection are spoken', () {
      final plan = suggestRunPlan(distanceM: 5000, goalTime: const Duration(minutes: 25));
      final c = Coach(plan: plan, zones: zones);
      final ev = runFor(c, 1600, (t) => 150, dist: (t) => t * 3.4);
      final splits = ev.where((e) => e.key == 'split').toList();
      expect(splits.length, 5);
      expect(splits.first.message, startsWith('Kilometre 1'));
      expect(ev.where((e) => e.key == 'projection'), isNotEmpty);
    });

    test('sensor loss is reported once per cooldown and recovery announced', () {
      final plan = suggestHrPlan(activity: 'Gym');
      final c = Coach(plan: plan, zones: zones);
      final ev = <CoachEvent>[];
      for (var t = 0; t < 120; t++) {
        final lost = t >= 30 && t < 90;
        ev.addAll(c.tick(CoachInput(
            t: t.toDouble(),
            moving: t.toDouble(),
            rawBpm: lost ? null : 110,
            contactOk: true,
            secondsSinceReading: lost ? (t - 30).toDouble() : 0)));
      }
      expect(ev.where((e) => e.key == 'sensor').length, 2);
      expect(ev.where((e) => e.key == 'sensor_back').length, 1);
    });

    test('flat line triggers a strap check', () {
      final plan = suggestRunPlan(distanceM: 21100);
      final c = Coach(plan: plan, zones: zones);
      final ev = runFor(c, 700, (t) => 170, dist: (t) => t * 2.0);
      expect(ev.where((e) => e.key == 'flatline'), isNotEmpty);
    });

    test('custom every-time rule fires on schedule', () {
      final plan = suggestRunPlan(distanceM: 10000);
      plan.rules.add(AlertRule(id: 'drink', trigger: TriggerKind.everyTime, value: 600, message: 'Drink'));
      final c = Coach(plan: plan, zones: zones);
      final ev = runFor(c, 1900, (t) => 150, dist: (t) => t * 3.0);
      expect(ev.where((e) => e.key == 'drink').length, 3);
    });

    test('muted rules stay quiet', () {
      final plan = suggestRunPlan(distanceM: 10000);
      final c = Coach(plan: plan, zones: zones)..mute('split');
      final ev = runFor(c, 700, (t) => 150, dist: (t) => t * 3.0);
      expect(ev.where((e) => e.key == 'split'), isEmpty);
    });

    test('interval timer cycles work and rest', () {
      final plan = suggestHrPlan(activity: 'HIIT', intervals: IntervalTimer(workSec: 30, restSec: 30, rounds: 3));
      final c = Coach(plan: plan, zones: zones);
      final ev = runFor(c, 200, (t) => 150);
      final msgs = ev.where((e) => e.key.startsWith('interval')).map((e) => e.message).toList();
      expect(msgs.first, contains('round 1 of 3'));
      expect(msgs.where((m) => m == 'Rest.').length, 2);
      expect(msgs.last, contains('Intervals done'));
    });

    test('time in zone progress', () {
      final plan = suggestHrPlan(activity: 'Indoor cycling', timeInZone: (zone: 2, minutes: 10));
      final c = Coach(plan: plan, zones: zones);
      final ev = runFor(c, 700, (t) => 145);
      final tiz = ev.where((e) => e.key == 'timeInZone').map((e) => e.message).toList();
      expect(tiz, ['5 of 10 minutes in zone 2 done.', 'Goal met: 10 minutes in zone 2.']);
    });

    test('merge speaks highest priority first', () {
      final u = mergeEvents([
        CoachEvent(key: 'a', label: 'a', message: 'Split.', priority: 5),
        CoachEvent(key: 'b', label: 'b', message: 'Signal lost.', priority: 1, safety: true),
      ])!;
      expect(u.text, 'Signal lost. Split.');
      expect(u.safety, true);
    });
  });

  group('stats', () {
    test('summary computes zones, splits and best efforts', () {
      final start = DateTime(2026, 1, 1, 8);
      final hr = <HrSample>[];
      final gps = <GpsPoint>[];
      for (var t = 0; t <= 1800; t++) {
        hr.add(HrSample(t * 1000, 140 + (t ~/ 300) + t % 7, true));
        if (t % 2 == 0) {
          gps.add(GpsPoint(tMs: t * 1000, lat: 0, lon: 0, dist: t * 3.0));
        }
      }
      final s = SessionRecord(
        kind: SessionKind.run,
        activity: 'Run',
        start: start,
        end: start.add(const Duration(seconds: 1800)),
        goalDistanceM: 5000,
        plan: suggestRunPlan(distanceM: 5000),
        movingS: 1800,
      );
      final data = SessionData(session: s, hr: hr, rr: [], gps: gps, alerts: [], intake: []);
      final res = computeSummary(data, Profile(age: 30, weightKg: 70, sex: Sex.male, restingHr: 60));
      expect(res['distanceM'], 5400);
      expect((res['splits'] as List).length, 6); // 5 full + partial
      expect(res['goalMet'], true);
      expect((res['bestEfforts'] as Map)['5 km'], closeTo(1666.7, 1));
      expect(res['kcal'], greaterThan(200));
      expect(res['takeaway'], isNotEmpty);
    });

    test('effort blocks find sets', () {
      final hr = <HrSample>[];
      for (var t = 0; t < 600; t++) {
        final work = (t ~/ 60).isOdd;
        hr.add(HrSample(t * 1000, work ? 160 : 110, true));
      }
      final blocks = effortBlocks(hr, 135, List.filled(hr.length, false));
      expect(blocks.length, 5);
    });
  });
}
