import 'dart:io';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/formulas.dart';
import '../core/models.dart';
import '../core/plan.dart';
import '../core/zones.dart';
import '../services/app_state.dart';
import '../services/db.dart';
import '../services/export.dart';
import '../services/session_controller.dart';
import 'widgets.dart';

class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key, required this.sessionId, this.fresh = false});
  final int sessionId;
  final bool fresh;

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  SessionData? data;
  Map<String, dynamic> get s => data!.session.summary ?? {};
  bool get metric => AppState.I.profile.metric;
  ZoneModel get zones => AppState.I.profile.zones;
  bool _askedMax = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rec = await AppDb.I.session(widget.sessionId);
    if (rec == null) return;
    if (rec.summary == null) await finaliseSession(rec, AppState.I.profile);
    final d = await AppDb.I.loadData(rec);
    if (!mounted) return;
    setState(() => data = d);
    if (widget.fresh && !_askedMax) {
      _askedMax = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeNewMax());
    }
  }

  Future<void> _maybeNewMax() async {
    final n = s['newMaxHr'] as int?;
    if (n == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('New max HR of $n detected'),
        content: const Text('This reading was held for 30 seconds with good contact and no stuck signal. Use it for your zones?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Use it')),
        ],
      ),
    );
    if (ok == true) {
      final p = AppState.I.profile;
      p.maxHrValue = n;
      p.maxHrSource = 'measured';
      p.maxHrUpdated = DateTime.now();
      await AppState.I.saveProfile();
    }
  }

  Future<void> _recompute() async {
    final rec = data!.session;
    await finaliseSession(rec, AppState.I.profile);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (data == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final rec = data!.session;
    final isRun = rec.kind == SessionKind.run;
    final tabs = [
      ('Summary', _summary()),
      ('Heart rate', _hrTab()),
      ('Zones', _zonesTab()),
      if (isRun) ('Splits', _splitsTab()),
      if (isRun && data!.gps.length > 1) ('Map', _mapTab()),
      ('Insights', _insightsTab()),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isRun ? 'Run' : rec.activity),
          actions: [
            PopupMenuButton<String>(
              onSelected: _menu,
              itemBuilder: (_) => [
                if (isRun && data!.gps.isNotEmpty) const PopupMenuItem(value: 'gpx', child: Text('Export GPX')),
                const PopupMenuItem(value: 'tcx', child: Text('Export TCX')),
                if (!isRun) const PopupMenuItem(value: 'manual', child: Text('Add distance or watts')),
                const PopupMenuItem(value: 'sweat', child: Text('Sweat test')),
                const PopupMenuItem(value: 'delete', child: Text('Delete session')),
              ],
            ),
          ],
          bottom: TabBar(isScrollable: true, tabs: [for (final t in tabs) Tab(text: t.$1)]),
        ),
        body: TabBarView(children: [for (final t in tabs) t.$2]),
      ),
    );
  }

  Future<void> _menu(String v) async {
    final rec = data!.session;
    switch (v) {
      case 'gpx':
      case 'tcx':
        final privacy = await showDialog<int>(
          context: context,
          builder: (c) => SimpleDialog(title: const Text('Hide start and end of the route?'), children: [
            for (final m in [0, 200, 300, 500])
              SimpleDialogOption(onPressed: () => Navigator.pop(c, m), child: Text(m == 0 ? 'Show everything' : 'Hide first and last $m m')),
          ]),
        );
        if (privacy == null) return;
        final text = v == 'gpx' ? toGpx(data!, privacyM: privacy.toDouble()) : toTcx(data!, privacyM: privacy.toDouble());
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/zonestep-${rec.start.toIso8601String().substring(0, 16).replaceAll(':', '')}.$v');
        await f.writeAsString(text);
        await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: 'Zonestep session'));
      case 'manual':
        final km = await askDouble(context, 'Distance (treadmill)', initial: rec.manualDistanceM == null ? null : rec.manualDistanceM! / 1000, suffix: 'km');
        if (!mounted) return;
        final w = await askDouble(context, 'Average power (indoor cycling)', initial: rec.manualWatts, suffix: 'W');
        rec.manualDistanceM = km == null || km <= 0 ? rec.manualDistanceM : km * 1000;
        rec.manualWatts = w == null || w <= 0 ? rec.manualWatts : w;
        await AppDb.I.updateSession(rec);
        await _recompute();
      case 'sweat':
        await _sweatTest();
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Delete this session?'),
            content: const Text('This removes it from your phone for good.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
            ],
          ),
        );
        if (ok == true) {
          await AppDb.I.deleteSession(rec.id!);
          if (mounted) Navigator.pop(context);
        }
    }
  }

  Future<void> _sweatTest() async {
    final before = await askDouble(context, 'Weight before', suffix: 'kg', initial: AppState.I.profile.weightKg);
    if (before == null || !mounted) return;
    final after = await askDouble(context, 'Weight after', suffix: 'kg');
    if (after == null || !mounted) return;
    final drank = await askDouble(context, 'What you drank', suffix: 'litres', initial: (s['waterMl'] as num? ?? 0) / 1000);
    if (drank == null || !mounted) return;
    final rate = sweatRate(
        weightBeforeKg: before,
        weightAfterKg: after,
        drankL: drank,
        duration: Duration(seconds: (s['movingS'] as num).round()));
    final loss = (before - after) / before * 100;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Sweat rate ${rate.toStringAsFixed(2)} L per hour'),
        content: Text('You lost ${loss.toStringAsFixed(1)}% of body weight. '
            '${loss > 2 ? 'More than 2% hurts endurance; drink a little more next time. ' : ''}'
            '${after > before ? 'You gained weight, which suggests drinking more than you sweat; drink to thirst. ' : ''}'
            'Use this to personalise future water reminders?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Use it')),
        ],
      ),
    );
    if (ok == true) {
      AppState.I.profile.sweatRateLph = rate;
      await AppState.I.saveProfile();
    }
  }

  Widget _summary() {
    final rec = data!.session;
    final dist = (s['distanceM'] as num?)?.toDouble() ?? 0;
    final goalMet = s['goalMet'] as bool?;
    final kcal = s['kcal'] as num?;
    final range = (s['kcalRange'] as List?)?.cast<num>();
    final wrist = rec.deviceKind == 'watch';
    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
      if (goalMet != null)
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: (goalMet ? Colors.green : Colors.orange).withValues(alpha: 0.2),
          child: ListTile(
            leading: Icon(goalMet ? Icons.emoji_events : Icons.flag_outlined, color: goalMet ? Colors.green : Colors.orange),
            title: Text(goalMet ? 'Goal met' : 'Goal missed', style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(_goalText(rec)),
          ),
        ),
      SectionCard(child: Text(s['takeaway'] as String? ?? '', style: const TextStyle(fontSize: 16))),
      SectionCard(
        trailing: wrist ? const Chip(label: Text('wrist reading'), visualDensity: VisualDensity.compact) : null,
        title: '${rec.start.day}/${rec.start.month}/${rec.start.year} ${rec.start.hour.toString().padLeft(2, '0')}:${rec.start.minute.toString().padLeft(2, '0')}',
        child: Wrap(spacing: 28, runSpacing: 16, children: [
          if (dist > 0) BigStat(label: 'Distance', value: fmtDistance(dist, metric: metric), unit: unitName(metric), size: 28),
          BigStat(label: 'Time', value: fmtDuration(Duration(seconds: (s['movingS'] as num).round())), size: 28),
          if (s['avgPace'] != null)
            BigStat(label: 'Avg pace', value: fmtPace((s['avgPace'] as num).toDouble(), metric: metric), unit: '/${unitName(metric)}', size: 28),
          if (s['avgHr'] != null) BigStat(label: 'Avg HR', value: '${(s['avgHr'] as num).round()}', unit: 'BPM', size: 28),
          if (s['maxHr'] != null) BigStat(label: 'Max HR', value: '${s['maxHr']}', unit: 'BPM', size: 28),
          if (kcal != null)
            Row(mainAxisSize: MainAxisSize.min, children: [
              BigStat(
                  label: 'Calories',
                  value: range != null ? '${range[0].round()}–${range[1].round()}' : '${kcal.round()}',
                  unit: 'kcal',
                  size: 28),
              const HowButton(
                  title: 'Calories',
                  text: 'Estimated from heart rate with the Keytel 2005 equation (age, weight, sex). On runs it is '
                      'cross-checked against the ACSM running equation from GPS speed; if they disagree by more than '
                      '25% a range is shown. Heart-rate calories can be off by a wide margin for one person, '
                      'especially at very easy efforts, near max, in heat, or with stress or caffeine.'),
            ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            BigStat(label: 'Training load', value: '${(s['trimp'] as num).round()}', size: 28),
            HowButton(
                title: 'Training load (TRIMP)',
                text: 'Banister TRIMP: minutes weighted by how high in your heart rate reserve you were. '
                    '${s['trimpAssumedRest'] == true ? 'Your resting HR is not set, so 60 BPM was assumed.' : ''}'),
          ]),
        ]),
      ),
      if ((s['carbsG'] as num? ?? 0) > 0 || (s['waterMl'] as num? ?? 0) > 0)
        SectionCard(
          title: 'Fuel',
          child: Text('Carbs ${(s['carbsG'] as num).round()} g (${(s['carbsPerHour'] as num).round()} g per hour) · '
              'water ${(s['waterMl'] as num).round()} ml'),
        ),
    ]);
  }

  String _goalText(SessionRecord rec) {
    final parts = <String>[];
    if (rec.goalDistanceM != null) parts.add('${fmtDistance(rec.goalDistanceM!, metric: metric, digits: 1)} ${unitName(metric)}');
    if (rec.goalTime != null) parts.add('in ${fmtDuration(rec.goalTime!)}');
    final tiz = rec.plan?.timeInZoneGoal;
    if (tiz != null) parts.add('${tiz.minutes} min in zone ${tiz.zone}');
    return parts.isEmpty ? '' : 'Goal: ${parts.join(' ')}';
  }

  Widget _hrTab() {
    final hr = data!.hr;
    if (hr.isEmpty) return const Center(child: Text('No heart rate recorded.'));
    final step = math.max(1, hr.length ~/ 600);
    final spots = <FlSpot>[
      for (var i = 0; i < hr.length; i += step)
        if (hr[i].contact) FlSpot(hr[i].tMs / 60000, hr[i].bpm.toDouble()) else FlSpot.nullSpot,
    ];
    final clean = hr.where((h) => h.contact && h.bpm >= 30).map((h) => h.bpm).toList();
    if (clean.isEmpty) return const Center(child: Text('No clean heart rate recorded.'));
    final minY = math.max(30, clean.reduce(math.min) - 10).toDouble();
    final maxY = math.max(minY + 20, math.min(230, clean.reduce(math.max) + 10)).toDouble();
    final alertsX = data!.alerts.map((a) => a.tMs / 60000).toList();
    final gps = data!.gps;
    final paceSpots = <FlSpot>[];
    for (var i = 10; i < gps.length; i += math.max(1, gps.length ~/ 300)) {
      final a = gps[i - 10], b = gps[i];
      final dd = b.dist - a.dist, dt = (b.tMs - a.tMs) / 1000;
      if (dd > 5 && dt > 0) {
        final pace = dt / dd * 1000 / 60 * (metric ? 1 : 1.609344);
        if (pace < 20) paceSpots.add(FlSpot(b.tMs / 60000, pace));
      }
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Heart rate on zone bands; dots on the top edge mark alerts.'),
      const SizedBox(height: 8),
      SizedBox(
        height: 260,
        child: LineChart(LineChartData(
          minY: minY,
          maxY: maxY,
          rangeAnnotations: RangeAnnotations(horizontalRangeAnnotations: [
            for (var z = 1; z <= 5; z++)
              HorizontalRangeAnnotation(
                  y1: zones.lowBpm(z).toDouble(), y2: zones.highBpm(z).toDouble() + 1, color: zoneColors[z].withValues(alpha: 0.18)),
          ]),
          extraLinesData: ExtraLinesData(verticalLines: [
            for (final x in alertsX)
              VerticalLine(x: x, color: Colors.white24, strokeWidth: 1, dashArray: [2, 4]),
          ]),
          titlesData: const FlTitlesData(
            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 24)),
            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 36)),
          ),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          lineBarsData: [
            LineChartBarData(spots: spots, color: Colors.redAccent, barWidth: 2, dotData: const FlDotData(show: false)),
          ],
        )),
      ),
      const Text('minutes', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
      if (paceSpots.length > 2) ...[
        const SizedBox(height: 24),
        Text('Pace (min per ${unitName(metric)})'),
        SizedBox(
          height: 160,
          child: LineChart(LineChartData(
            titlesData: const FlTitlesData(
              topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 24)),
              leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 36)),
            ),
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            lineBarsData: [
              LineChartBarData(spots: paceSpots, color: Colors.lightBlueAccent, barWidth: 2, dotData: const FlDotData(show: false)),
            ],
          )),
        ),
      ],
      if ((s['flatlineS'] as int? ?? 0) > 0)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text('${((s['flatlineS'] as int) / 60).round()} min of stuck readings were left out of the stats.',
              style: const TextStyle(color: Colors.amber)),
        ),
    ]);
  }

  Widget _zonesTab() {
    final tz = (s['timeInZones'] as List).cast<num>();
    final total = tz.fold<num>(0, (a, b) => a + b);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(zones.describe(), style: const TextStyle(fontSize: 12)),
      const SizedBox(height: 12),
      for (var z = 5; z >= 0; z--)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            SizedBox(width: 44, child: ZoneBadge(z)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(z == 0 ? 'Below zone 1 (<${zones.lowBpm(1)})' : '${ZoneModel.names[z]} ${zones.lowBpm(z)}–${zones.highBpm(z)}',
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 2),
                LinearProgressIndicator(
                  value: total == 0 ? 0 : tz[z] / total,
                  minHeight: 14,
                  color: zoneColors[z],
                  borderRadius: BorderRadius.circular(4),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: Text('${(tz[z] / 60).round()} min · ${total == 0 ? 0 : (tz[z] / total * 100).round()}%', textAlign: TextAlign.right),
            ),
          ]),
        ),
    ]);
  }

  Widget _splitsTab() {
    final splits = (s['splits'] as List).cast<Map>();
    if (splits.isEmpty) return const Center(child: Text('Not enough distance for splits.'));
    return SingleChildScrollView(
      child: DataTable(
        columnSpacing: 18,
        columns: [
          DataColumn(label: Text(unitName(metric))),
          const DataColumn(label: Text('Pace')),
          const DataColumn(label: Text('Avg HR')),
          const DataColumn(label: Text('Max')),
          const DataColumn(label: Text('Elev')),
        ],
        rows: [
          for (final sp in splits)
            DataRow(
              color: WidgetStatePropertyAll(sp['index'] == s['fastestSplit']
                  ? Colors.green.withValues(alpha: 0.2)
                  : sp['index'] == s['hardestSplit']
                      ? Colors.red.withValues(alpha: 0.15)
                      : null),
              cells: [
                DataCell(Text(sp['partialM'] != null ? '${sp['index']}*' : '${sp['index']}')),
                DataCell(Text(fmtPace((sp['pace'] as num).toDouble()))),
                DataCell(Text(sp['avgHr'] == null ? '--' : '${(sp['avgHr'] as num).round()}')),
                DataCell(Text(sp['maxHr'] == null ? '--' : '${sp['maxHr']}')),
                DataCell(Text(sp['elev'] == null ? '--' : '${(sp['elev'] as num) >= 0 ? '+' : ''}${(sp['elev'] as num).round()} m')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _mapTab() => _RouteMap(data: data!, zones: zones, metric: metric);

  Widget _insightsTab() {
    final drift = s['driftPct'] as num?;
    final efforts = (s['efforts'] as List?)?.cast<Map>() ?? [];
    final adherence = (s['adherence'] as List?)?.cast<Map>() ?? [];
    final counts = (s['alertCounts'] as Map?)?.cast<String, dynamic>() ?? {};
    final best = (s['bestEfforts'] as Map?)?.cast<String, dynamic>() ?? {};
    final muted = (s['muted'] as List?)?.cast<String>() ?? [];
    final rec = data!.session;
    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
      SectionCard(
        title: 'Heart',
        child: Column(children: [
          _metric(
              'Cardiac drift',
              drift == null ? 'Not enough data' : '${drift.toStringAsFixed(1)}%',
              s['driftKind'] == 'decoupling'
                  ? 'Pace-to-heart-rate decoupling between the first and second half (after a 10% warm-up). Under 5% means you held your effort well.'
                  : 'Rise in average heart rate from the first to the second half.'),
          if (s['metresPerBeat'] != null)
            _metric('Efficiency', '${(s['metresPerBeat'] as num).toStringAsFixed(2)} m per beat',
                'Distance divided by heartbeats. Rising over weeks means fitness is improving.'),
          if (s['wattsPerBeat'] != null)
            _metric('Power per beat', '${(s['wattsPerBeat'] as num).toStringAsFixed(2)} W/BPM', 'Average watts divided by average heart rate.'),
          _metric('Recovery (1 min)', s['hrr60'] == null ? 'Not measured' : '${s['hrr60']} BPM drop',
              'Heart rate drop in the first 60 s after finishing (Cole et al. 1999). Larger is better.'),
          _metric(
              'HRV (RMSSD)',
              s['rmssd'] == null
                  ? (s['rrAvailable'] == true ? 'Signal not clean enough' : 'Not available from this device')
                  : '${(s['rmssd'] as num).toStringAsFixed(0)} ms',
              'Beat-to-beat variation from RR intervals (ESC/NASPE 1996). During exercise it is naturally low; it is most '
                  'useful from still, free-monitoring sessions.'),
        ]),
      ),
      if (efforts.isNotEmpty && rec.kind == SessionKind.hrOnly)
        SectionCard(
          title: 'Effort blocks (${efforts.length})',
          child: Column(children: [
            for (var i = 0; i < efforts.length; i++)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('Set ${i + 1}: peak ${efforts[i]['peak']} BPM'),
                subtitle: Text('${(efforts[i]['durationS'] as num).round()} s above ${zones.recoveryLevel}'
                    '${efforts[i]['recovery60'] != null ? ' · dropped ${efforts[i]['recovery60']} BPM in 60 s' : ''}'),
              ),
          ]),
        ),
      if (adherence.isNotEmpty)
        SectionCard(
          title: 'Plan adherence',
          child: Column(children: [
            for (final a in adherence)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(a['name'] as String),
                trailing: Text(a['pct'] == null ? '--' : '${(a['pct'] as num).round()}% in target'),
              ),
          ]),
        ),
      if (counts.isNotEmpty)
        SectionCard(
          title: 'Alerts fired',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final e in counts.entries) Text('${_alertName(e.key, rec)}: ${e.value}'),
            if (muted.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Muted: ${muted.map((m) => _alertName(m, rec)).join(', ')}'),
            ],
          ]),
        ),
      if (best.isNotEmpty)
        SectionCard(
          title: 'Best efforts in this run',
          child: Column(children: [
            for (final e in best.entries)
              ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.key),
                  trailing: Text(fmtDuration(Duration(seconds: (e.value as num).round())))),
          ]),
        ),
    ]);
  }

  String _alertName(String key, SessionRecord rec) {
    for (final b in BuiltIn.values) {
      if (b.name == key) return b.label;
    }
    final r = rec.plan?.rules.where((r) => r.id == key);
    if (r != null && r.isNotEmpty) return r.first.message;
    return switch (key) {
      'segment' => 'Segment change',
      'sensor_back' => 'Signal back',
      'battery' => 'Sensor battery',
      _ => key.startsWith('interval') ? 'Interval timer' : key,
    };
  }

  Widget _metric(String label, String value, String how) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        trailing: HowButton(title: label, text: how),
      );
}

class _RouteMap extends StatefulWidget {
  const _RouteMap({required this.data, required this.zones, required this.metric});
  final SessionData data;
  final ZoneModel zones;
  final bool metric;

  @override
  State<_RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<_RouteMap> {
  String? info;
  bool load = false;

  int? _bpmAt(int tMs) {
    final hr = widget.data.hr;
    if (hr.isEmpty) return null;
    var lo = 0, hi = hr.length - 1;
    while (hi - lo > 1) {
      final m = (lo + hi) ~/ 2;
      if (hr[m].tMs <= tMs) {
        lo = m;
      } else {
        hi = m;
      }
    }
    return hr[lo].bpm;
  }

  @override
  Widget build(BuildContext context) {
    if (!load) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('The map background is downloaded from OpenStreetMap, which sees the general area being viewed. '
                'Your route itself never leaves the phone.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => setState(() => load = true), child: const Text('Show map')),
          ]),
        ),
      );
    }
    final gps = widget.data.gps;
    final pts = [for (final g in gps) LatLng(g.lat, g.lon)];
    final lines = <Polyline>[];
    for (var i = 1; i < gps.length; i++) {
      final b = _bpmAt(gps[i].tMs);
      final z = b == null ? 0 : widget.zones.zoneOf(b);
      lines.add(Polyline(points: [pts[i - 1], pts[i]], color: zoneColors[z], strokeWidth: 5));
    }
    return Stack(children: [
      FlutterMap(
        options: MapOptions(
          initialCameraFit:
              CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(32), maxZoom: 18),
          onTap: (_, p) {
            var best = 0;
            var bestD = double.infinity;
            for (var i = 0; i < gps.length; i++) {
              final d = haversine(p.latitude, p.longitude, gps[i].lat, gps[i].lon);
              if (d < bestD) {
                bestD = d;
                best = i;
              }
            }
            if (bestD > 100) return;
            final g = gps[best];
            final a = gps[math.max(0, best - 10)];
            final pace = g.dist - a.dist > 5 ? (g.tMs - a.tMs) / 1000 / (g.dist - a.dist) * 1000 : null;
            setState(() => info = '${fmtDistance(g.dist, metric: widget.metric)} ${unitName(widget.metric)} · '
                '${_bpmAt(g.tMs) ?? '--'} BPM · ${fmtPace(pace, metric: widget.metric)}/${unitName(widget.metric)}');
          },
        ),
        children: [
          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.zonestep.app'),
          PolylineLayer(polylines: lines),
          const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
        ],
      ),
      if (info != null)
        Positioned(
          left: 16,
          right: 16,
          top: 16,
          child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(info!))),
        ),
    ]);
  }
}
