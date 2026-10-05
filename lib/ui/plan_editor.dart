import 'package:flutter/material.dart';

import '../core/coach.dart';
import '../core/plan.dart';
import '../core/zones.dart';
import '../services/app_state.dart';
import '../services/db.dart';
import 'widgets.dart';

/// Coloured bar of the plan's segments, by target zone.
class PlanBar extends StatelessWidget {
  const PlanBar({super.key, required this.plan, this.height = 22, this.onTapSegment});
  final AlertPlan plan;
  final double height;
  final void Function(int)? onTapSegment;

  @override
  Widget build(BuildContext context) {
    final total = plan.segments.isEmpty ? 1 : plan.segments.last.end;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: height,
        child: Row(children: [
          for (var i = 0; i < plan.segments.length; i++)
            Expanded(
              flex: ((plan.segments[i].end - plan.segments[i].start) / total * 1000).round().clamp(1, 1000),
              child: GestureDetector(
                onTap: onTapSegment == null ? null : () => onTapSegment!(i),
                child: Container(
                  color: zoneColors[plan.segments[i].zoneHigh],
                  alignment: Alignment.center,
                  margin: const EdgeInsets.only(right: 1),
                  child: Text('Z${plan.segments[i].zoneLow}${plan.segments[i].zoneHigh != plan.segments[i].zoneLow ? '-${plan.segments[i].zoneHigh}' : ''}',
                      overflow: TextOverflow.clip,
                      maxLines: 1,
                      style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key});

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  List<AlertPlan> plans = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await AppDb.I.plans();
    if (mounted) setState(() => plans = p);
  }

  Future<void> _new() async {
    final km = await askDouble(context, 'Distance for the new plan', suffix: 'km');
    if (km == null || km <= 0 || !mounted) return;
    final plan = suggestRunPlan(distanceM: km * 1000);
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PlanEditorScreen(plan: plan, saveOnly: true)));
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Alert plans')),
        floatingActionButton: FloatingActionButton(onPressed: _new, child: const Icon(Icons.add)),
        body: plans.isEmpty
            ? const Center(
                child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('No saved plans yet. Tap + to build one, or edit a suggested plan before a run and save it.',
                    textAlign: TextAlign.center),
              ))
            : ListView(children: [
                for (final p in plans)
                  ListTile(
                    leading: Icon(p.kind == SessionKind.run ? Icons.directions_run : Icons.favorite),
                    title: Text(p.name),
                    subtitle: Text('${p.segments.length} segments · ${p.rules.length} custom alerts${p.isDefault ? ' · default' : ''}'),
                    onTap: () async {
                      await Navigator.push(
                          context, MaterialPageRoute(builder: (_) => PlanEditorScreen(plan: p.copy(), saveOnly: true)));
                      _load();
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await AppDb.I.deletePlan(p.id!);
                        _load();
                      },
                    ),
                  ),
              ]),
      );
}

/// The alert planner: segments, repeat blocks, custom rules, built-in
/// switches and a preview of where alerts will fire.
class PlanEditorScreen extends StatefulWidget {
  const PlanEditorScreen({super.key, required this.plan, this.saveOnly = false});
  final AlertPlan plan;
  final bool saveOnly;

  @override
  State<PlanEditorScreen> createState() => _PlanEditorScreenState();
}

class _PlanEditorScreenState extends State<PlanEditorScreen> {
  AlertPlan get plan => widget.plan;
  bool get metric => AppState.I.profile.metric;
  bool get byDistance => plan.axis == PlanAxis.distance;
  ZoneModel get zones => AppState.I.profile.zones;

  String _pos(double v) => byDistance
      ? '${fmtDistance(v, metric: metric, digits: 1)} ${unitName(metric)}'
      : fmtDuration(Duration(seconds: v.round()));

  double get _unit => byDistance ? (metric ? 1000 : 1609.344) : 60;
  String get _unitLabel => byDistance ? unitName(metric) : 'min';

  void _normalise() {
    for (var i = 1; i < plan.segments.length; i++) {
      plan.segments[i].start = plan.segments[i - 1].end;
    }
  }

  Future<void> _editSegment(int i) async {
    final s = plan.segments[i].copy();
    final name = TextEditingController(text: s.name);
    final end = TextEditingController(text: (s.end / _unit).toStringAsFixed(2));
    final ceil = TextEditingController(text: s.ceiling?.toString() ?? '');
    final floor = TextEditingController(text: s.floor?.toString() ?? '');
    final pace = TextEditingController(text: s.paceSecPerKm == null ? '' : fmtPace(s.paceSecPerKm, metric: metric));
    final res = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text('Segment ${i + 1}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
              TextField(
                  controller: end,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: 'Ends at', suffixText: _unitLabel)),
              Row(children: [
                const Text('Zones '),
                DropdownButton<int>(
                    value: s.zoneLow,
                    items: [for (var z = 1; z <= 5; z++) DropdownMenuItem(value: z, child: Text('$z'))],
                    onChanged: (v) => set(() {
                          s.zoneLow = v!;
                          if (s.zoneHigh < v) s.zoneHigh = v;
                        })),
                const Text(' to '),
                DropdownButton<int>(
                    value: s.zoneHigh,
                    items: [for (var z = s.zoneLow; z <= 5; z++) DropdownMenuItem(value: z, child: Text('$z'))],
                    onChanged: (v) => set(() => s.zoneHigh = v!)),
              ]),
              Text('${zones.lowBpm(s.zoneLow)}–${zones.highBpm(s.zoneHigh)} BPM', style: const TextStyle(fontSize: 12)),
              TextField(
                  controller: ceil,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: 'HR ceiling (blank = top of zone ${s.zoneHigh})', suffixText: 'BPM')),
              TextField(
                  controller: floor,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: 'HR floor (blank = bottom of zone ${s.zoneLow})', suffixText: 'BPM')),
              if (byDistance)
                TextField(
                    controller: pace,
                    decoration: InputDecoration(labelText: 'Target pace (optional)', hintText: 'm:ss', suffixText: '/${unitName(metric)}')),
            ]),
          ),
          actions: [
            if (plan.segments.length > 1)
              TextButton(onPressed: () => Navigator.pop(c, 'delete'), child: const Text('Delete')),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, 'ok'), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (res == 'delete') {
      setState(() {
        final removed = plan.segments.removeAt(i);
        if (i > 0) {
          plan.segments[i - 1].end = removed.end;
        } else {
          plan.segments.first.start = 0;
        }
        _normalise();
      });
      return;
    }
    if (res != 'ok') return;
    s.name = name.text.trim().isEmpty ? s.name : name.text.trim();
    final e = double.tryParse(end.text.replaceAll(',', '.'));
    if (e != null) s.end = (e * _unit).clamp(s.start + 1, double.infinity);
    s.ceiling = int.tryParse(ceil.text.trim());
    s.floor = int.tryParse(floor.text.trim());
    final pc = parseClock(pace.text);
    s.paceSecPerKm = pc == null ? null : (metric ? pc.inSeconds.toDouble() : pc.inSeconds / 1.609344);
    setState(() {
      plan.segments[i] = s;
      // Keep later segments after this one.
      for (var k = i + 1; k < plan.segments.length; k++) {
        if (plan.segments[k].end <= plan.segments[k - 1].end) plan.segments[k].end = plan.segments[k - 1].end + _unit * 0.1;
      }
      _normalise();
      if (byDistance && plan.distanceM != null) plan.distanceM = plan.segments.last.end;
    });
  }

  void _addSegment() {
    final last = plan.segments.last;
    setState(() {
      plan.segments.add(Segment(
          name: 'Segment ${plan.segments.length + 1}',
          start: last.end,
          end: last.end + _unit,
          zoneLow: last.zoneLow,
          zoneHigh: last.zoneHigh));
      if (byDistance) plan.distanceM = plan.segments.last.end;
    });
  }

  Future<void> _addRepeat() async {
    final reps = TextEditingController(text: '6');
    final work = TextEditingController(text: byDistance ? '0.8' : '3');
    final rest = TextEditingController(text: byDistance ? '0.4' : '2');
    var workZone = 4, restZone = 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Repeat block'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: reps, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Repeats')),
            TextField(
                controller: work,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Work length', suffixText: _unitLabel)),
            Row(children: [
              const Text('Work zone '),
              DropdownButton<int>(
                  value: workZone,
                  items: [for (var z = 1; z <= 5; z++) DropdownMenuItem(value: z, child: Text('$z'))],
                  onChanged: (v) => set(() => workZone = v!)),
            ]),
            TextField(
                controller: rest,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Recovery length', suffixText: _unitLabel)),
            Row(children: [
              const Text('Recovery zone '),
              DropdownButton<int>(
                  value: restZone,
                  items: [for (var z = 1; z <= 5; z++) DropdownMenuItem(value: z, child: Text('$z'))],
                  onChanged: (v) => set(() => restZone = v!)),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final n = int.tryParse(reps.text) ?? 0;
    final w = (double.tryParse(work.text.replaceAll(',', '.')) ?? 0) * _unit;
    final r = (double.tryParse(rest.text.replaceAll(',', '.')) ?? 0) * _unit;
    if (n <= 0 || w <= 0) return;
    setState(() {
      var pos = plan.segments.last.end;
      for (var i = 1; i <= n; i++) {
        plan.segments.add(Segment(name: 'Rep $i', start: pos, end: pos + w, zoneLow: workZone, zoneHigh: workZone));
        pos += w;
        if (r > 0) {
          plan.segments.add(Segment(name: 'Recovery $i', start: pos, end: pos + r, zoneLow: restZone, zoneHigh: restZone, floor: 0));
          pos += r;
        }
      }
      if (byDistance) plan.distanceM = pos;
    });
  }

  Future<void> _editRule([AlertRule? existing]) async {
    final r = existing?.copy() ??
        AlertRule(id: newRuleId(), trigger: byDistance ? TriggerKind.everyDistance : TriggerKind.everyTime, message: '');
    final msg = TextEditingController(text: r.message);
    final value = TextEditingController(text: _valueToText(r));
    final hold = TextEditingController(text: r.holdSec.toString());
    final cooldown = TextEditingController(text: r.cooldownSec.toString());
    final maxRep = TextEditingController(text: r.maxRepeats?.toString() ?? '');
    final res = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        final needsValue = !{TriggerKind.enterZone, TriggerKind.leaveZone, TriggerKind.segmentStart, TriggerKind.segmentEnd}
            .contains(r.trigger);
        final needsHold = {TriggerKind.hrAbove, TriggerKind.hrBelow, TriggerKind.paceFaster, TriggerKind.paceSlower}
            .contains(r.trigger);
        return AlertDialog(
          title: Text(existing == null ? 'New alert' : 'Edit alert'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              DropdownButton<TriggerKind>(
                isExpanded: true,
                value: r.trigger,
                items: [
                  for (final t in TriggerKind.values)
                    if (byDistance || !{TriggerKind.atDistance, TriggerKind.everyDistance, TriggerKind.paceFaster, TriggerKind.paceSlower}.contains(t))
                      DropdownMenuItem(value: t, child: Text(triggerLabels[t]!)),
                ],
                onChanged: (v) => set(() {
                  r.trigger = v!;
                  value.text = '';
                }),
              ),
              if (needsValue)
                TextField(
                    controller: value,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: _valueLabel(r.trigger), hintText: _valueHint(r.trigger))),
              if (needsHold)
                TextField(
                    controller: hold,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'For at least', suffixText: 's')),
              if (r.trigger == TriggerKind.enterZone || r.trigger == TriggerKind.leaveZone)
                DropdownButton<int>(
                  value: r.zone ?? 3,
                  items: [for (var z = 1; z <= 5; z++) DropdownMenuItem(value: z, child: Text('Zone $z'))],
                  onChanged: (v) => set(() => r.zone = v),
                ),
              DropdownButton<int?>(
                isExpanded: true,
                value: r.segment,
                items: [
                  DropdownMenuItem(
                      value: null,
                      child: Text(r.trigger == TriggerKind.segmentStart || r.trigger == TriggerKind.segmentEnd
                          ? 'Any segment'
                          : 'Whole session')),
                  for (var i = 0; i < plan.segments.length; i++)
                    DropdownMenuItem(value: i, child: Text('Only in ${plan.segments[i].name}')),
                ],
                onChanged: (v) => set(() => r.segment = v),
              ),
              TextField(
                  controller: msg,
                  decoration: const InputDecoration(
                      labelText: 'Message', hintText: 'e.g. Gel now. Use {bpm}, {zone}, {distance}, {time}')),
              Wrap(spacing: 6, children: [
                for (final m in ['Gel now', 'Drink', 'Relax your shoulders', 'Check your form', 'Heart rate {bpm}'])
                  ActionChip(label: Text(m), onPressed: () => set(() => msg.text = m)),
              ]),
              DropdownButton<RuleDelivery>(
                value: r.delivery,
                items: const [
                  DropdownMenuItem(value: RuleDelivery.voice, child: Text('Voice')),
                  DropdownMenuItem(value: RuleDelivery.vibrate, child: Text('Vibration only')),
                  DropdownMenuItem(value: RuleDelivery.notification, child: Text('Notification')),
                  DropdownMenuItem(value: RuleDelivery.log, child: Text('Log only')),
                ],
                onChanged: (v) => set(() => r.delivery = v!),
              ),
              TextField(
                  controller: cooldown,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Cooldown', suffixText: 's')),
              TextField(
                  controller: maxRep,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Max repeats (blank = no limit)')),
            ]),
          ),
          actions: [
            if (existing != null) TextButton(onPressed: () => Navigator.pop(c, 'delete'), child: const Text('Delete')),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, 'ok'), child: const Text('Save')),
          ],
        );
      }),
    );
    if (res == 'delete') {
      setState(() => plan.rules.removeWhere((x) => x.id == r.id));
      return;
    }
    if (res != 'ok') return;
    r.message = msg.text.trim().isEmpty ? 'Alert' : msg.text.trim();
    r.value = _textToValue(r.trigger, value.text) ?? r.value;
    r.holdSec = int.tryParse(hold.text) ?? 0;
    r.cooldownSec = int.tryParse(cooldown.text) ?? 45;
    r.maxRepeats = int.tryParse(maxRep.text);
    if (r.trigger == TriggerKind.enterZone || r.trigger == TriggerKind.leaveZone) r.zone ??= 3;
    setState(() {
      final i = plan.rules.indexWhere((x) => x.id == r.id);
      if (i >= 0) {
        plan.rules[i] = r;
      } else {
        plan.rules.add(r);
      }
    });
  }

  String _valueLabel(TriggerKind t) => switch (t) {
        TriggerKind.atDistance || TriggerKind.everyDistance => 'Distance (${unitName(metric)})',
        TriggerKind.atTime || TriggerKind.everyTime => 'Minutes',
        TriggerKind.hrAbove || TriggerKind.hrBelow => 'Heart rate (BPM)',
        TriggerKind.paceFaster || TriggerKind.paceSlower => 'Pace (m:ss per ${unitName(metric)})',
        _ => 'Value',
      };

  String? _valueHint(TriggerKind t) => t == TriggerKind.paceFaster || t == TriggerKind.paceSlower ? '5:45' : null;

  String _valueToText(AlertRule r) {
    final u = metric ? 1000 : 1609.344;
    return switch (r.trigger) {
      TriggerKind.atDistance || TriggerKind.everyDistance => r.value == 0 ? '' : (r.value / u).toStringAsFixed(2),
      TriggerKind.atTime || TriggerKind.everyTime => r.value == 0 ? '' : (r.value / 60).toStringAsFixed(1),
      TriggerKind.paceFaster || TriggerKind.paceSlower => r.value == 0 ? '' : fmtPace(r.value, metric: metric),
      TriggerKind.hrAbove || TriggerKind.hrBelow => r.value == 0 ? '' : r.value.round().toString(),
      _ => '',
    };
  }

  double? _textToValue(TriggerKind t, String text) {
    final u = metric ? 1000 : 1609.344;
    if (t == TriggerKind.paceFaster || t == TriggerKind.paceSlower) {
      final d = parseClock(text);
      if (d == null) return null;
      return metric ? d.inSeconds.toDouble() : d.inSeconds / 1.609344;
    }
    final v = double.tryParse(text.replaceAll(',', '.'));
    if (v == null) return null;
    return switch (t) {
      TriggerKind.atDistance || TriggerKind.everyDistance => v * u,
      TriggerKind.atTime || TriggerKind.everyTime => v * 60,
      _ => v,
    };
  }

  String _ruleSummary(AlertRule r) {
    final when = switch (r.trigger) {
      TriggerKind.atDistance => 'At ${_pos(r.value)}',
      TriggerKind.atTime => 'At ${fmtDuration(Duration(seconds: r.value.round()))}',
      TriggerKind.everyDistance => 'Every ${fmtDistance(r.value, metric: metric, digits: 1)} ${unitName(metric)}',
      TriggerKind.everyTime => 'Every ${(r.value / 60).toStringAsFixed(0)} min',
      TriggerKind.hrAbove => 'HR above ${r.value.round()} for ${r.holdSec} s',
      TriggerKind.hrBelow => 'HR below ${r.value.round()} for ${r.holdSec} s',
      TriggerKind.enterZone => 'Entering zone ${r.zone}',
      TriggerKind.leaveZone => 'Leaving zone ${r.zone}',
      TriggerKind.paceFaster => 'Pace faster than ${fmtPace(r.value, metric: metric)} for ${r.holdSec} s',
      TriggerKind.paceSlower => 'Pace slower than ${fmtPace(r.value, metric: metric)} for ${r.holdSec} s',
      TriggerKind.segmentStart => 'Start of ${r.segment == null ? 'each segment' : plan.segments[r.segment!.clamp(0, plan.segments.length - 1)].name}',
      TriggerKind.segmentEnd => 'End of ${r.segment == null ? 'each segment' : plan.segments[r.segment!.clamp(0, plan.segments.length - 1)].name}',
    };
    final scope = r.segment != null && r.trigger != TriggerKind.segmentStart && r.trigger != TriggerKind.segmentEnd
        ? ' (${plan.segments[r.segment!.clamp(0, plan.segments.length - 1)].name})'
        : '';
    return '$when$scope · ${r.delivery.name}';
  }

  Future<void> _toggleBuiltIn(BuiltIn b, bool v) async {
    if (!v && BuiltIn.safetyCritical.contains(b)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Turn off "${b.label}"?'),
          content: const Text('This alert is on by default because it catches a dead strap, a stuck reading or a long time '
              'above your ceiling. Without it you may not notice until after the session.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep on')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Turn off')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => plan.builtIns[b] = v);
  }

  Future<void> _save() async {
    final name = TextEditingController(text: plan.name);
    var isDefault = plan.isDefault;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Save plan'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            if (plan.kind == SessionKind.run && plan.distanceM != null)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Default for ${fmtDistance(plan.distanceM!, metric: metric, digits: 1)} ${unitName(metric)}'),
                value: isDefault,
                onChanged: (v) => set(() => isDefault = v ?? false),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    plan.name = name.text.trim().isEmpty ? plan.name : name.text.trim();
    plan.isDefault = isDefault;
    await AppDb.I.savePlan(plan);
    if (mounted) snack(context, 'Plan saved');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final preview = previewAlerts(plan, metric: metric);
    final crowded = <double>[];
    for (var i = 1; i < preview.length; i++) {
      final gap = preview[i].$1 - preview[i - 1].$1;
      if (byDistance ? gap < 250 : gap < 60) crowded.add(preview[i].$1);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alert planner'),
        actions: [
          IconButton(icon: const Icon(Icons.save_outlined), tooltip: 'Save as plan', onPressed: _save),
        ],
      ),
      floatingActionButton: widget.saveOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: () => Navigator.pop(context, plan),
              icon: const Icon(Icons.check),
              label: const Text('Use this plan'),
            ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          SectionCard(
            title: 'Segments',
            trailing: Text(byDistance && plan.distanceM != null
                ? '${fmtDistance(plan.distanceM!, metric: metric, digits: 1)} ${unitName(metric)}'
                : ''),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              PlanBar(plan: plan, height: 30, onTapSegment: _editSegment),
              const SizedBox(height: 4),
              const Text('Tap a segment to edit it.', style: TextStyle(fontSize: 12)),
              for (var i = 0; i < plan.segments.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: ZoneBadge(plan.segments[i].zoneHigh),
                  title: Text(plan.segments[i].name),
                  subtitle: Text([
                    '${_pos(plan.segments[i].start)}–${_pos(plan.segments[i].end)}',
                    'zone ${plan.segments[i].zoneLow}${plan.segments[i].zoneHigh != plan.segments[i].zoneLow ? '–${plan.segments[i].zoneHigh}' : ''}',
                    'ceiling ${plan.segments[i].ceilingBpm(zones)}',
                    if (plan.segments[i].paceSecPerKm != null)
                      '${fmtPace(plan.segments[i].paceSecPerKm, metric: metric)}/${unitName(metric)}',
                  ].join(' · ')),
                  onTap: () => _editSegment(i),
                ),
              Wrap(spacing: 8, children: [
                OutlinedButton.icon(onPressed: _addSegment, icon: const Icon(Icons.add), label: const Text('Segment')),
                OutlinedButton.icon(onPressed: _addRepeat, icon: const Icon(Icons.repeat), label: const Text('Repeat block')),
              ]),
            ]),
          ),
          SectionCard(
            title: 'Custom alerts',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final r in plan.rules)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(r.message),
                  subtitle: Text(_ruleSummary(r)),
                  value: r.enabled,
                  onChanged: (v) => setState(() => r.enabled = v),
                  secondary: IconButton(icon: const Icon(Icons.edit), onPressed: () => _editRule(r)),
                ),
              OutlinedButton.icon(onPressed: () => _editRule(), icon: const Icon(Icons.add_alert), label: const Text('Add alert')),
            ]),
          ),
          SectionCard(
            title: 'Coach alerts',
            child: Column(children: [
              for (final b in BuiltIn.values)
                if (_relevant(b))
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(b.label),
                    subtitle: BuiltIn.safetyCritical.contains(b) ? const Text('On by default for safety') : null,
                    value: plan.on(b),
                    onChanged: (v) => _toggleBuiltIn(b, v),
                  ),
              if (plan.kind == SessionKind.run)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Add calories to splits'),
                  value: plan.kcalWithSplit,
                  onChanged: (v) => setState(() => plan.kcalWithSplit = v),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Default cooldown per alert type'),
                subtitle: Text('${AppState.I.profile.defaultCooldownSec} s (change in Settings)'),
              ),
            ]),
          ),
          SectionCard(
            title: 'Preview',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(plan.goalTime == null && byDistance
                  ? 'Timed alerts are placed assuming 6:00 per km.'
                  : 'Where alerts are expected to fire at goal pace.'),
              if (crowded.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('${crowded.length} alerts land very close to another one; they will be merged when spoken.',
                      style: const TextStyle(color: Colors.amber)),
                ),
              for (final e in preview.take(80))
                Text('${_pos(e.$1).padRight(10)}  ${e.$2}', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
              if (preview.length > 80) Text('…and ${preview.length - 80} more'),
            ]),
          ),
        ],
      ),
    );
  }

  bool _relevant(BuiltIn b) {
    if (plan.kind == SessionKind.run) {
      return !{BuiltIn.timeInZone, BuiltIn.recovered, BuiltIn.intervals}.contains(b);
    }
    return !{BuiltIn.split, BuiltIn.projection, BuiltIn.drift, BuiltIn.finalPush, BuiltIn.sustainability}.contains(b);
  }
}
