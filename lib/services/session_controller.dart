import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/coach.dart';
import '../core/formulas.dart';
import '../core/models.dart';
import '../core/plan.dart';
import '../core/profile.dart';
import '../core/stats.dart';
import 'app_state.dart';
import 'ble_service.dart';
import 'db.dart';
import 'foreground.dart';
import 'location_service.dart';
import 'voice_service.dart';

enum SessionPhase { running, recovery, finished }

class LoggedAlert {
  LoggedAlert(this.t, this.label, this.message);
  final double t;
  final String label;
  final String message;
}

/// Runs one live session: collects samples, feeds the coach, speaks alerts,
/// and writes everything to the database in batches every few seconds.
class SessionController extends ChangeNotifier {
  SessionController({required this.plan, required this.profile});

  static SessionController? active;

  final AlertPlan plan;
  final Profile profile;
  late final Coach coach;
  late SessionRecord record;
  LocationTracker? tracker;
  SessionPhase phase = SessionPhase.running;

  late DateTime start;
  Timer? _timer;
  StreamSubscription<TimedReading>? _hrSub;
  StreamSubscription<GpsPoint>? _gpsSub;

  final _hrBuf = <HrSample>[];
  final _rrBuf = <RrPoint>[];
  final _gpsBuf = <GpsPoint>[];
  final _alertBuf = <AlertLogEntry>[];
  final _intakeBuf = <IntakeEntry>[];
  final List<GpsPoint> route = [];

  double movingS = 0;
  double kcal = 0;
  bool manualPause = false;
  int? bpm;
  bool contactOk = true;
  final List<LoggedAlert> recent = [];
  double carbsG = 0;
  double waterMl = 0;
  int _tickN = 0;
  double recoveryLeft = 60;
  double _pausedS = 0;
  DateTime? _endAt;

  bool get isRun => plan.kind == SessionKind.run;
  double get elapsed => DateTime.now().difference(start).inMilliseconds / 1000;
  double? get distance => tracker?.distance;
  bool get autoPaused => isRun && tracker != null && !tracker!.moving;

  /// Returns false when the background service could not start.
  Future<bool> begin() async {
    coach = Coach(plan: plan, zones: profile.zones, metric: profile.metric, defaultCooldown: profile.defaultCooldownSec);
    start = DateTime.now();
    final dev = AppState.I.device;
    record = SessionRecord(
      kind: plan.kind,
      activity: plan.activity,
      start: start,
      goalDistanceM: plan.distanceM,
      goalTime: plan.goalTime,
      plan: plan,
      deviceId: dev?.id,
      deviceKind: dev?.kind,
    );
    record.id = await AppDb.I.insertSession(record);
    active = this;

    final kept = await ForegroundSession.start(withLocation: isRun, text: 'Starting…');
    VoiceService.I.delivery = profile.delivery;

    _hrSub = BleService.I.readings.listen((r) {
      // The beats in a notification happened before it arrived.
      final t = r.at.difference(start).inMilliseconds;
      final total = r.reading.rrMs.fold<double>(0, (a, b) => a + b);
      var acc = 0.0;
      for (final rr in r.reading.rrMs) {
        acc += rr;
        _rrBuf.add(RrPoint(t - (total - acc).round(), rr));
      }
    });

    if (isRun) {
      tracker = LocationTracker(ultra: plan.ultra, autoPause: profile.autoPause)..start(start);
      _gpsSub = tracker!.points.listen((p) {
        _gpsBuf.add(p);
        route.add(p);
      });
    }

    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    final goal = isRun && plan.distanceM != null
        ? '${fmtDistance(plan.distanceM!, metric: profile.metric, digits: plan.distanceM! % 1000 == 0 ? 0 : 1)} ${unitName(profile.metric)}'
        : plan.activity;
    unawaited(VoiceService.I.alert('Session started. $goal. Good luck.'));
    notifyListeners();
    return kept;
  }

  void _tick() {
    if (phase == SessionPhase.recovery) {
      _recoveryTick();
      return;
    }
    if (phase != SessionPhase.running) return;
    _tickN++;
    final t = elapsed;
    final ble = BleService.I;
    final fresh = ble.secondsSinceReading <= 3;
    final reading = ble.last?.reading;
    bpm = fresh ? reading?.bpm : null;
    contactOk = reading?.hasContact ?? true;
    if (fresh && reading != null) {
      _hrBuf.add(HrSample((t * 1000).round(), reading.bpm, reading.hasContact));
    }

    if (manualPause) _pausedS += 1;
    tracker?.checkStale();
    final isMoving = !manualPause && (!isRun || (tracker?.moving ?? true));
    if (isMoving) movingS += 1;

    if (!manualPause) {
      final b = bpm;
      if (b != null && contactOk && profile.canEstimateCalories) {
        kcal += keytelKcalPerMin(bpm: b.toDouble(), age: profile.age!, weightKg: profile.weightKg!, sex: profile.sex) / 60;
      }
      // The coach's clock skips manual pauses so holds and interval phases
      // don't run on while paused.
      final events = coach.tick(CoachInput(
        t: t - _pausedS,
        moving: movingS,
        rawBpm: bpm?.toDouble(),
        contactOk: contactOk,
        secondsSinceReading: ble.secondsSinceReading,
        distanceM: tracker?.distance,
        isMoving: isMoving,
        battery: ble.battery,
        kcal: kcal,
      ));
      _handle(events, t);
    }

    if (_tickN % 5 == 0) {
      unawaited(_flush());
      unawaited(ForegroundSession.update(_notificationTitle(), _notificationText()));
    }
    notifyListeners();
  }

  void _handle(List<CoachEvent> events, double t) {
    if (events.isEmpty) return;
    for (final e in events) {
      _alertBuf.add(AlertLogEntry((t * 1000).round(), e.key, e.message));
      recent.insert(0, LoggedAlert(t, e.label, e.message));
    }
    if (recent.length > 30) recent.removeRange(30, recent.length);
    final u = mergeEvents(events);
    if (u != null) unawaited(VoiceService.I.alert(u.text, safety: u.safety));
    if (events.any((e) => e.delivery == RuleDelivery.vibrate) && u == null) {
      unawaited(VoiceService.I.vibrate());
    }
    final note = events.where((e) => e.delivery == RuleDelivery.notification).toList();
    if (note.isNotEmpty) unawaited(ForegroundSession.update(note.first.message, _notificationText()));
  }

  String _notificationTitle() {
    final b = bpm;
    if (b == null) return 'Heart rate signal lost';
    final z = profile.zones.zoneOf(b);
    return '♥ $b BPM · Zone $z';
  }

  String _notificationText() {
    final parts = <String>[fmtDuration(Duration(seconds: movingS.round()))];
    final d = distance;
    if (d != null) parts.add('${fmtDistance(d, metric: profile.metric)} ${unitName(profile.metric)}');
    if (autoPaused) parts.add('auto-paused');
    if (manualPause) parts.add('paused');
    return parts.join(' · ');
  }

  Future<void> _flush() async {
    final id = record.id;
    if (id == null) return;
    final hr = List<HrSample>.of(_hrBuf);
    final rr = List<RrPoint>.of(_rrBuf);
    final gps = List<GpsPoint>.of(_gpsBuf);
    final al = List<AlertLogEntry>.of(_alertBuf);
    final il = List<IntakeEntry>.of(_intakeBuf);
    _hrBuf.clear();
    _rrBuf.clear();
    _gpsBuf.clear();
    _alertBuf.clear();
    _intakeBuf.clear();
    try {
      await AppDb.I.writeSamples(sessionId: id, hr: hr, rr: rr, gps: gps, alerts: al, intake: il);
      record.movingS = movingS;
      record.muted = coach.muted.toList();
      await AppDb.I.updateSession(record);
    } catch (e) {
      debugPrint('flush failed: $e');
    }
  }

  void togglePause() {
    manualPause = !manualPause;
    unawaited(VoiceService.I.say(manualPause ? 'Paused.' : 'Resumed.'));
    notifyListeners();
  }

  void mute(String key) {
    coach.mute(key);
    notifyListeners();
  }

  void logIntake(String kind, double amount) {
    _intakeBuf.add(IntakeEntry((elapsed * 1000).round(), kind, amount));
    if (kind == 'carb') carbsG += amount;
    if (kind == 'water') waterMl += amount;
    notifyListeners();
  }

  /// Stops recording and starts the 60-second heart rate recovery check.
  Future<void> finish({bool measureRecovery = true}) async {
    if (phase != SessionPhase.running) return;
    _endAt = DateTime.now();
    await tracker?.stop();
    await _gpsSub?.cancel();
    await _flush();
    if (measureRecovery && bpm != null) {
      record.recoveryStartBpm = bpm;
      phase = SessionPhase.recovery;
      recoveryLeft = 60;
      unawaited(VoiceService.I.say('Session done. Keep the strap on and stand still for one minute to measure recovery.'));
      notifyListeners();
    } else {
      await _finalise();
    }
  }

  void _recoveryTick() {
    recoveryLeft -= 1;
    if (recoveryLeft <= 0) {
      record.recoveryEndBpm = BleService.I.secondsSinceReading <= 3 ? BleService.I.last?.reading.bpm : null;
      if (record.recoveryEndBpm == null) record.recoveryStartBpm = null;
      unawaited(_finalise());
    }
    notifyListeners();
  }

  Future<void> skipRecovery() async {
    record.recoveryStartBpm = null;
    await _finalise();
  }

  Future<void> _finalise() async {
    if (phase == SessionPhase.finished) return;
    phase = SessionPhase.finished;
    _timer?.cancel();
    await _hrSub?.cancel();
    record.end = _endAt ?? DateTime.now();
    record.movingS = movingS;
    record.muted = coach.muted.toList();
    try {
      await AppDb.I.updateSession(record);
      await finaliseSession(record, profile);
      unawaited(VoiceService.I.say(_closingLine()));
    } catch (e) {
      debugPrint('finalise failed: $e');
    } finally {
      await ForegroundSession.stop();
      active = null;
      notifyListeners();
    }
  }

  String _closingLine() {
    final parts = <String>['Saved.'];
    final d = distance;
    if (d != null && d > 100) {
      parts.add('${fmtDistance(d, metric: profile.metric)} ${profile.metric ? 'kilometres' : 'miles'}');
    }
    parts.add('in ${fmtDuration(Duration(seconds: movingS.round()))}.');
    return parts.join(' ');
  }

  /// Abandon without saving.
  Future<void> discard() async {
    phase = SessionPhase.finished;
    _timer?.cancel();
    await _hrSub?.cancel();
    await tracker?.stop();
    await _gpsSub?.cancel();
    await ForegroundSession.stop();
    if (record.id != null) await AppDb.I.deleteSession(record.id!);
    active = null;
    notifyListeners();
  }
}

/// Computes and caches the summary for a finished session.
Future<Map<String, dynamic>> finaliseSession(SessionRecord record, Profile profile) async {
  final data = await AppDb.I.loadData(record);
  final summary = computeSummary(data, profile);
  record.summary = summary;
  await AppDb.I.saveSplits(record.id!, (summary['splits'] as List).cast<Map<String, dynamic>>());
  await AppDb.I.updateSession(record);
  return summary;
}

/// Closes sessions left open by a crash or a killed app.
Future<void> recoverUnfinished(Profile profile) async {
  for (final s in await AppDb.I.unfinishedSessions()) {
    final last = await AppDb.I.lastSampleT(s.id!); // HR or GPS, whichever is later
    if (last == null || last < 60000) {
      await AppDb.I.deleteSession(s.id!);
      continue;
    }
    s.end = s.start.add(Duration(milliseconds: last));
    if (s.movingS <= 0) s.movingS = last / 1000;
    await finaliseSession(s, profile);
  }
}
