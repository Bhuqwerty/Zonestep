import 'package:flutter/material.dart';

import '../core/coach.dart';
import '../core/plan.dart';
import '../core/zones.dart';
import '../services/ble_service.dart';
import '../services/session_controller.dart';
import 'summary_screen.dart';
import 'widgets.dart';

/// One large screen readable at arm's length mid-stride.
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key, required this.controller});
  final SessionController controller;

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  SessionController get c => widget.controller;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (c.phase == SessionPhase.finished && !_navigated && mounted) {
      _navigated = true;
      final id = c.record.id;
      if (id != null && c.record.end != null) {
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => SummaryScreen(sessionId: id, fresh: true)));
      } else {
        Navigator.pop(context);
      }
    }
  }

  Future<void> _confirmFinish() async {
    final r = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.flag),
              title: const Text('Finish and save'),
              subtitle: const Text('Then keep the strap on for a minute to measure recovery'),
              onTap: () => Navigator.pop(ctx, 'finish')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Discard session'), onTap: () => Navigator.pop(ctx, 'discard')),
          ListTile(leading: const Icon(Icons.close), title: const Text('Keep going'), onTap: () => Navigator.pop(ctx)),
        ]),
      ),
    );
    if (r == 'finish') await c.finish();
    if (r == 'discard') await c.discard();
  }

  void _muteSheet() {
    final keys = <String, String>{
      for (final b in BuiltIn.values)
        if (c.plan.on(b)) b.name: b.label,
      for (final r in c.plan.rules)
        if (r.enabled) r.id: r.message,
    };
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => ListView(children: [
          const ListTile(title: Text('Mute for the rest of this session', style: TextStyle(fontWeight: FontWeight.bold))),
          for (final e in keys.entries)
            CheckboxListTile(
              title: Text(e.value),
              value: c.coach.muted.contains(e.key),
              onChanged: (v) {
                if (v == true) {
                  c.mute(e.key);
                } else {
                  c.coach.muted.remove(e.key);
                }
                set(() {});
              },
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: c.phase == SessionPhase.finished,
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          if (c.phase == SessionPhase.recovery) return _recovery();
          return Scaffold(
            body: SafeArea(child: _body()),
          );
        },
      ),
    );
  }

  Widget _recovery() => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Measuring recovery', textAlign: TextAlign.center, style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Text('Keep the strap on and stand still for one minute.', textAlign: TextAlign.center),
              const SizedBox(height: 32),
              Text('${c.recoveryLeft.round()} s', textAlign: TextAlign.center, style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w800)),
              ListenableBuilder(
                listenable: BleService.I,
                builder: (_, __) => Text(
                    BleService.I.last == null ? '' : '${BleService.I.last!.reading.bpm} BPM (from ${c.record.recoveryStartBpm})',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 22)),
              ),
              const SizedBox(height: 32),
              OutlinedButton(onPressed: c.skipRecovery, child: const Text('Skip')),
            ]),
          ),
        ),
      );

  Widget _body() {
    final zones = c.profile.zones;
    final metric = c.profile.metric;
    final bpm = c.bpm;
    final zone = bpm == null ? null : zones.zoneOf(bpm);
    final color = zone == null ? Colors.grey : zoneColors[zone];
    final seg = c.coach.segment;
    final next = c.coach.nextSegment;
    final dist = c.distance;
    final goal = c.plan.distanceM;
    final paceKm = c.coach.currentPace;
    double? projected;
    if (dist != null && goal != null && c.coach.paceLastKm != null && dist < goal) {
      projected = c.movingS + (goal - dist) / 1000 * c.coach.paceLastKm!;
    }
    final fuel = c.plan.rules.any((r) => r.enabled && r.category == 'carb');
    final water = c.plan.rules.any((r) => r.enabled && r.category == 'water');
    final phaseLeft = c.coach.phaseRemaining(c.elapsed);
    return Column(children: [
      // Zone band: colour plus number.
      Container(
        color: color,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          zone == null
              ? (BleService.I.isConnected ? 'NO SIGNAL' : 'RECONNECTING…')
              : 'ZONE $zone · ${ZoneModel.names[zone].toUpperCase()}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 20, letterSpacing: 1.5),
        ),
      ),
      Expanded(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(bpm?.toString() ?? '--', style: const TextStyle(fontSize: 112, fontWeight: FontWeight.w900, height: 1)),
            const SizedBox(width: 8),
            const Padding(padding: EdgeInsets.only(bottom: 16), child: Text('BPM', style: TextStyle(fontSize: 22))),
            const Spacer(),
            if (!c.contactOk) const Icon(Icons.sensors_off, color: Colors.redAccent, size: 32),
          ]),
          if (seg != null)
            Text('Target ${seg.zoneLow == seg.zoneHigh ? 'zone ${seg.zoneLow}' : 'zones ${seg.zoneLow}–${seg.zoneHigh}'} · '
                'ceiling ${seg.ceilingBpm(zones)}',
                style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 12),
          Wrap(spacing: 28, runSpacing: 12, children: [
            BigStat(label: 'Time', value: fmtDuration(Duration(seconds: c.movingS.round()))),
            if (dist != null) BigStat(label: 'Distance', value: fmtDistance(dist, metric: metric), unit: unitName(metric)),
            if (dist != null && goal != null)
              BigStat(label: 'Left', value: fmtDistance((goal - dist).clamp(0, goal), metric: metric), unit: unitName(metric)),
            if (dist != null) BigStat(label: 'Pace', value: fmtPace(paceKm, metric: metric), unit: '/${unitName(metric)}'),
            if (projected != null) BigStat(label: 'Projected', value: fmtDuration(Duration(seconds: projected.round()))),
            if (c.kcal > 0) BigStat(label: 'kcal', value: c.kcal.round().toString()),
            if (phaseLeft != null)
              BigStat(label: c.coach.phase == IntervalPhase.work ? 'Work' : 'Rest', value: '${phaseLeft.round()} s'),
            if (c.plan.timeInZoneGoal != null)
              BigStat(
                  label: 'Zone ${c.plan.timeInZoneGoal!.zone} time',
                  value: '${(c.coach.targetSeconds / 60).floor()}/${c.plan.timeInZoneGoal!.minutes}',
                  unit: 'min'),
          ]),
          if (c.autoPaused || c.manualPause)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(c.manualPause ? 'Paused' : 'Auto-paused', style: const TextStyle(fontSize: 20, color: Colors.amber)),
            ),
          if (seg != null && c.plan.segments.length > 1) ...[
            const SizedBox(height: 16),
            Text('Now: ${seg.name}${next != null ? '   Next: ${next.name} (zone ${next.zoneLow}${next.zoneHigh != next.zoneLow ? '–${next.zoneHigh}' : ''})' : ''}',
                style: const TextStyle(fontSize: 16)),
          ],
          if (c.recent.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('"${c.recent.first.message}"', style: const TextStyle(fontStyle: FontStyle.italic)),
          ],
          if (fuel || water) ...[
            const SizedBox(height: 16),
            Row(children: [
              if (fuel)
                Expanded(
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
                    onPressed: () => c.logIntake('carb', _servingG()),
                    child: Text('Carbs taken\n${c.carbsG.round()} g', textAlign: TextAlign.center),
                  ),
                ),
              if (fuel && water) const SizedBox(width: 8),
              if (water)
                Expanded(
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
                    onPressed: () => c.logIntake('water', _sipMl()),
                    child: Text('Drank\n${c.waterMl.round()} ml', textAlign: TextAlign.center),
                  ),
                ),
            ]),
          ],
        ]),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          IconButton.filledTonal(iconSize: 30, onPressed: _muteSheet, icon: const Icon(Icons.volume_off), tooltip: 'Mute alerts'),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.tonal(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(60)),
              onPressed: c.togglePause,
              child: Text(c.manualPause ? 'Resume' : 'Pause', style: const TextStyle(fontSize: 20)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(60), backgroundColor: Colors.redAccent),
              onPressed: _confirmFinish,
              child: const Text('Finish', style: TextStyle(fontSize: 20)),
            ),
          ),
        ]),
      ),
    ]);
  }

  double _sipMl() {
    final r = c.plan.rules.firstWhere((r) => r.category == 'water');
    final m = RegExp(r'(\d+) millilitres').firstMatch(r.message);
    return m == null ? 150 : double.parse(m.group(1)!);
  }

  double _servingG() {
    final r = c.plan.rules.firstWhere((r) => r.category == 'carb');
    final m = RegExp(r'(\d+) grams').firstMatch(r.message);
    return m == null ? 25 : double.parse(m.group(1)!);
  }
}
