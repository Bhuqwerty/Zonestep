import 'dart:async';

import 'package:flutter/material.dart';

import '../core/formulas.dart';
import '../core/plan.dart';
import '../services/app_state.dart';
import '../services/ble_service.dart';
import '../services/db.dart';
import '../services/location_service.dart';
import '../services/session_controller.dart';
import 'device_screens.dart';
import 'live_screen.dart';
import 'plan_editor.dart';
import 'widgets.dart';

class RunSetupScreen extends StatefulWidget {
  const RunSetupScreen({super.key});

  @override
  State<RunSetupScreen> createState() => _RunSetupScreenState();
}

class _RunSetupScreenState extends State<RunSetupScreen> {
  double distanceM = 5000;
  final _goal = TextEditingController();
  bool firstTime = false;
  bool carbs = true;
  double gelG = 25;
  bool water = true;
  bool hotDay = false;
  List<AlertPlan> saved = [];
  AlertPlan? chosen; // null = suggested
  AlertPlan? edited;

  bool get metric => AppState.I.profile.metric;

  @override
  void initState() {
    super.initState();
    AppDb.I.plans(kind: SessionKind.run).then((p) {
      saved = p;
      _pickDefault();
    });
  }

  Future<void> _pickDefault() async {
    final d = await AppDb.I.defaultPlanFor(distanceM);
    if (!mounted) return;
    setState(() {
      chosen = d;
      edited = null;
    });
  }

  Duration? get goal => _goal.text.trim().isEmpty ? null : parseClock(_goal.text);

  AlertPlan get plan {
    if (edited != null) return edited!;
    if (chosen != null) {
      final c = chosen!.copy();
      c.goalTime = goal ?? c.goalTime;
      return c;
    }
    return suggestRunPlan(
      distanceM: distanceM,
      goalTime: goal,
      firstTime: firstTime,
      gelGrams: gelG,
      carbs: carbs,
      water: water,
      hotDay: hotDay,
      sweatRateLph: AppState.I.profile.sweatRateLph,
    );
  }

  @override
  Widget build(BuildContext context) {
    final unit = metric ? 1000.0 : 1609.344;
    final presets = metric ? [3000.0, 5000.0, 10000.0, 21097.5, 42195.0] : [1609.344 * 3.1, 1609.344 * 6.2, 1609.344 * 13.1, 42195.0];
    final p = plan;
    final expected = p.goalTime ?? Duration(seconds: (distanceM / 1000 * 360).round());
    final carb = carbTarget(expected);
    final main = p.segments.length > 2 ? p.segments[1] : p.segments.first;
    return Scaffold(
      appBar: AppBar(title: const Text('Run')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          SectionCard(
            title: 'Distance',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final d in presets)
                  ChoiceChip(
                    label: Text(d == 21097.5
                        ? 'Half'
                        : d == 42195.0
                            ? 'Marathon'
                            : '${(d / unit).toStringAsFixed(d / unit % 1 == 0 ? 0 : 1)} ${unitName(metric)}'),
                    selected: (distanceM - d).abs() < 1,
                    onSelected: (_) {
                      distanceM = d;
                      _pickDefault();
                    },
                  ),
                ActionChip(
                  label: const Text('Custom'),
                  onPressed: () async {
                    final v = await askDouble(context, 'Distance', suffix: unitName(metric));
                    if (v != null && v > 0) {
                      distanceM = v * unit;
                      _pickDefault();
                    }
                  },
                ),
              ]),
              const SizedBox(height: 8),
              Text('Goal: ${fmtDistance(distanceM, metric: metric, digits: 2)} ${unitName(metric)}'),
              const SizedBox(height: 12),
              TextField(
                controller: _goal,
                decoration: const InputDecoration(labelText: 'Target time (optional)', hintText: 'h:mm:ss or mm:ss'),
                onChanged: (_) => setState(() => edited = null),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('First time at this distance'),
                value: firstTime,
                onChanged: (v) => setState(() {
                  firstTime = v ?? false;
                  edited = null;
                }),
              ),
            ]),
          ),
          SectionCard(
            title: 'Plan',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DropdownButton<int?>(
                isExpanded: true,
                value: chosen?.id,
                items: [
                  const DropdownMenuItem(value: null, child: Text('Suggested plan')),
                  for (final s in saved) DropdownMenuItem(value: s.id, child: Text(s.name + (s.isDefault ? ' (default)' : ''))),
                ],
                onChanged: (id) => setState(() {
                  chosen = id == null ? null : saved.firstWhere((s) => s.id == id);
                  edited = null;
                }),
              ),
              Text('Target: zone ${main.zoneLow}${main.zoneHigh != main.zoneLow ? '–${main.zoneHigh}' : ''} in the ${main.name.toLowerCase()}'),
              const SizedBox(height: 6),
              PlanBar(plan: p),
              const SizedBox(height: 6),
              Text('${p.segments.length} segments, ${p.rules.where((r) => r.enabled).length} custom alerts'
                  '${p.ultra ? ' · ultra mode: GPS every 4 s, alerts limited to splits, fuel, water and safety' : ''}'),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit plan'),
                  onPressed: () async {
                    final r = await Navigator.push<AlertPlan>(
                        context, MaterialPageRoute(builder: (_) => PlanEditorScreen(plan: p.copy())));
                    if (r != null) setState(() => edited = r);
                  },
                ),
              ),
            ]),
          ),
          if (chosen == null && edited == null)
            SectionCard(
              title: 'Fuel and water',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(carb.note, style: const TextStyle(fontSize: 13)),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Carb reminders'),
                  value: carbs,
                  onChanged: (v) => setState(() => carbs = v),
                ),
                if (carbs)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('What you carry'),
                    subtitle: Text('${gelG.round()} g per gel or serving'),
                    trailing: const Icon(Icons.edit),
                    onTap: () async {
                      final v = await askDouble(context, 'Carbs per serving', initial: gelG, suffix: 'g');
                      if (v != null && v > 0) setState(() => gelG = v);
                    },
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Water reminders'),
                  subtitle: const Text('Drink to thirst; small sips every 15–20 minutes on runs over 45 minutes.'),
                  value: water,
                  onChanged: (v) => setState(() => water = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Hot day'),
                  subtitle: const Text('Moves water reminders toward the upper end.'),
                  value: hotDay,
                  onChanged: (v) => setState(() => hotDay = v),
                ),
              ]),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => startSession(context, plan),
        icon: const Icon(Icons.play_arrow),
        label: const Text('Start'),
      ),
    );
  }
}

class HrSetupScreen extends StatefulWidget {
  const HrSetupScreen({super.key});

  @override
  State<HrSetupScreen> createState() => _HrSetupScreenState();
}

class _HrSetupScreenState extends State<HrSetupScreen> {
  String activity = hrActivities.first;
  String goalType = 'none';
  int minutes = 45;
  int tizZone = 2;
  int tizMinutes = 20;
  bool intervals = false;
  int work = 40, rest = 20, rounds = 8;
  bool earlyRest = false;
  AlertPlan? edited;

  AlertPlan get plan =>
      edited ??
      suggestHrPlan(
        activity: activity,
        timeGoal: goalType == 'time' ? Duration(minutes: minutes) : null,
        timeInZone: goalType == 'zone' ? (zone: tizZone, minutes: tizMinutes) : null,
        intervals: intervals ? IntervalTimer(workSec: work, restSec: rest, rounds: rounds, endRestOnRecovery: earlyRest) : null,
      );

  void _changed(VoidCallback f) => setState(() {
        f();
        edited = null;
      });

  @override
  Widget build(BuildContext context) {
    final z = AppState.I.profile.zones;
    return Scaffold(
      appBar: AppBar(title: const Text('Heart rate only')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('Uses only your strap: no location, no map, no distance.'),
          ),
          SectionCard(
            title: 'Activity',
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final a in hrActivities)
                ChoiceChip(label: Text(a), selected: a == activity, onSelected: (_) => _changed(() => activity = a)),
            ]),
          ),
          SectionCard(
            title: 'Goal',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'none', label: Text('None')),
                  ButtonSegment(value: 'time', label: Text('Time')),
                  ButtonSegment(value: 'zone', label: Text('Time in zone')),
                ],
                selected: {goalType},
                onSelectionChanged: (s) => _changed(() => goalType = s.first),
              ),
              if (goalType == 'time')
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('$minutes minutes'),
                  trailing: const Icon(Icons.edit),
                  onTap: () async {
                    final v = await askInt(context, 'Minutes', initial: minutes);
                    if (v != null && v > 0) _changed(() => minutes = v);
                  },
                ),
              if (goalType == 'zone') ...[
                Row(children: [
                  const Text('Zone '),
                  DropdownButton<int>(
                    value: tizZone,
                    items: [for (var i = 1; i <= 5; i++) DropdownMenuItem(value: i, child: Text('$i  (${z.lowBpm(i)}–${z.highBpm(i)})'))],
                    onChanged: (v) => _changed(() => tizZone = v!),
                  ),
                ]),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('$tizMinutes minutes in zone $tizZone'),
                  trailing: const Icon(Icons.edit),
                  onTap: () async {
                    final v = await askInt(context, 'Minutes in zone', initial: tizMinutes);
                    if (v != null && v > 0) _changed(() => tizMinutes = v);
                  },
                ),
              ],
            ]),
          ),
          SectionCard(
            title: 'Interval timer',
            child: Column(children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Work and rest timer'),
                value: intervals,
                onChanged: (v) => _changed(() => intervals = v),
              ),
              if (intervals) ...[
                _numTile('Work', work, 's', (v) => work = v),
                _numTile('Rest', rest, 's', (v) => rest = v),
                _numTile('Rounds', rounds, '', (v) => rounds = v),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('End rest early when recovered'),
                  subtitle: Text('When heart rate drops below ${z.recoveryLevel} (top of zone 2).'),
                  value: earlyRest,
                  onChanged: (v) => _changed(() => earlyRest = v),
                ),
              ],
            ]),
          ),
          SectionCard(
            title: 'Alerts',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Target zone ${plan.segments.first.zoneLow}–${plan.segments.first.zoneHigh}, '
                  '${BuiltIn.values.where(plan.on).length} coach alerts on'),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit in alert planner'),
                  onPressed: () async {
                    final r = await Navigator.push<AlertPlan>(
                        context, MaterialPageRoute(builder: (_) => PlanEditorScreen(plan: plan.copy())));
                    if (r != null) setState(() => edited = r);
                  },
                ),
              ),
            ]),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => startSession(context, plan),
        icon: const Icon(Icons.play_arrow),
        label: const Text('Start'),
      ),
    );
  }

  Widget _numTile(String label, int v, String unit, void Function(int) set) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('$label: $v$unit'),
        trailing: const Icon(Icons.edit),
        onTap: () async {
          final n = await askInt(context, label, initial: v);
          if (n != null && n > 0) _changed(() => set(n));
        },
      );
}

/// Permissions, a 5-second signal check, then the live screen.
Future<void> startSession(BuildContext context, AlertPlan plan) async {
  if (SessionController.active != null) {
    snack(context, 'A session is already running.');
    return;
  }
  // Android 14 only lets the session's background service start while
  // "Nearby devices" is granted, so re-check it (it can be auto-revoked).
  if (!await BleService.I.ensurePermissions()) {
    if (context.mounted) snack(context, 'Zonestep needs the "Nearby devices" permission to read your strap.');
    return;
  }
  if (!context.mounted) return;
  final dev = AppState.I.device;
  if (dev == null) {
    final d = await Navigator.push(context, MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (d == null || !context.mounted) return;
  }
  if (plan.kind == SessionKind.run) {
    final err = await LocationTracker.ensurePermission();
    if (err != null) {
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('No GPS'),
          content: Text('$err\n\nYou can still use a "Heart rate only" session, which needs no location.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          ],
        ),
      );
      if (go != true) return;
    }
  }
  if (!context.mounted) return;
  final ok = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => const _SignalCheck());
  if (ok != true || !context.mounted) return;
  final c = SessionController(plan: plan, profile: AppState.I.profile);
  final kept = await c.begin();
  if (!context.mounted) return;
  if (!kept) {
    snack(context, 'Android would not keep Zonestep running in the background. Keep the screen on, or check app permissions.');
  }
  Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => LiveScreen(controller: c)));
}

class _SignalCheck extends StatefulWidget {
  const _SignalCheck();

  @override
  State<_SignalCheck> createState() => _SignalCheckState();
}

class _SignalCheckState extends State<_SignalCheck> {
  int left = 5;
  Timer? _t;
  bool? passed;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  void _begin() {
    final ble = BleService.I;
    final d = AppState.I.device;
    if (!ble.isConnected && d != null) ble.connect(d.id, d.name);
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      left--;
      if (left <= 0) {
        t.cancel();
        final last = ble.last;
        passed = ble.secondsSinceReading < 3 && last != null && last.reading.hasContact;
        if (passed!) Navigator.pop(context, true);
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ble = BleService.I;
    return AlertDialog(
      title: const Text('Signal check'),
      content: ListenableBuilder(
        listenable: ble,
        builder: (_, __) => Column(mainAxisSize: MainAxisSize.min, children: [
          Text(ble.last != null && ble.secondsSinceReading < 3 ? '${ble.last!.reading.bpm} BPM' : '--',
              style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (passed == null) Text('Checking the heart rate signal… $left'),
          if (passed == false)
            Text(ble.isConnected
                ? 'No clean heart rate yet. Wet the strap pads and check it sits snugly.'
                : 'The device is not connected. Wake the strap by putting it on, or switch on broadcast on your watch.'),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        if (passed == false) TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Start anyway')),
        if (passed == false)
          FilledButton(
              onPressed: () => setState(() {
                    passed = null;
                    left = 5;
                    _begin();
                  }),
              child: const Text('Retry')),
      ],
    );
  }
}
