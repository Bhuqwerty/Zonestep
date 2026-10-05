import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/plan.dart';
import '../core/stats.dart';
import '../services/app_state.dart';
import '../services/db.dart';
import 'home_screen.dart';
import 'summary_screen.dart';
import 'widgets.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<SessionRecord> sessions = [];
  bool loaded = false;
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);

  bool get metric => AppState.I.profile.metric;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await AppDb.I.sessions();
    if (mounted) {
      setState(() {
        sessions = s;
        loaded = true;
      });
    }
  }

  DateTime _weekStart(DateTime d) => DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('History'),
            bottom: const TabBar(tabs: [Tab(text: 'Sessions'), Tab(text: 'Trends')]),
          ),
          body: !loaded
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(children: [_list(), _trends()]),
        ),
      );

  Widget _list() {
    if (sessions.isEmpty) return const Center(child: Text('No sessions yet.'));
    return ListView(children: [
      _calendar(),
      for (final s in sessions)
        SessionTile(
          session: s,
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => SummaryScreen(sessionId: s.id!)));
            _load();
          },
        ),
    ]);
  }

  Widget _calendar() {
    final first = DateTime(month.year, month.month, 1);
    final days = DateTime(month.year, month.month + 1, 0).day;
    final offset = first.weekday - 1;
    final active = <int, SessionKind>{};
    for (final s in sessions) {
      if (s.start.year == month.year && s.start.month == month.month) active[s.start.day] = s.kind;
    }
    const names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return SectionCard(
      title: '${names[month.month - 1]} ${month.year}',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
            icon: const Icon(Icons.chevron_left), onPressed: () => setState(() => month = DateTime(month.year, month.month - 1))),
        IconButton(
            icon: const Icon(Icons.chevron_right), onPressed: () => setState(() => month = DateTime(month.year, month.month + 1))),
      ]),
      child: GridView.count(
        crossAxisCount: 7,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final d in ['M', 'T', 'W', 'T', 'F', 'S', 'S']) Center(child: Text(d, style: const TextStyle(fontSize: 11))),
          for (var i = 0; i < offset; i++) const SizedBox(),
          for (var d = 1; d <= days; d++)
            Center(
              child: Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: active.containsKey(d)
                    ? BoxDecoration(
                        color: active[d] == SessionKind.run ? Colors.redAccent : Colors.orangeAccent, shape: BoxShape.circle)
                    : null,
                child: Text('$d', style: TextStyle(color: active.containsKey(d) ? Colors.black : null)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _trends() {
    if (sessions.isEmpty) return const Center(child: Text('Trends appear after a few sessions.'));
    final now = _weekStart(DateTime.now());
    final weeks = List.generate(8, (i) => now.subtract(Duration(days: 7 * (7 - i))));
    final dist = List<double>.filled(8, 0);
    final load = List<double>.filled(8, 0);
    for (final s in sessions) {
      final w = _weekStart(s.start);
      final i = weeks.indexWhere((x) => x == w);
      if (i < 0) continue;
      dist[i] += ((s.summary?['distanceM'] as num?) ?? 0).toDouble();
      load[i] += ((s.summary?['trimp'] as num?) ?? 0).toDouble();
    }
    final runs = sessions.where((s) => s.kind == SessionKind.run && s.summary?['metresPerBeat'] != null).toList().reversed.toList();
    final eff = [
      for (var i = 0; i < runs.length; i++) FlSpot(i.toDouble(), (runs[i].summary!['metresPerBeat'] as num).toDouble()),
    ];
    final best = <String, (double, SessionRecord)>{};
    for (final s in sessions) {
      final b = (s.summary?['bestEfforts'] as Map?)?.cast<String, dynamic>() ?? {};
      for (final e in b.entries) {
        final t = (e.value as num).toDouble();
        if (!best.containsKey(e.key) || t < best[e.key]!.$1) best[e.key] = (t, s);
      }
    }
    final unit = metric ? 1000 : 1609.344;
    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
      SectionCard(title: 'Weekly distance (${unitName(metric)})', child: _bars(dist.map((d) => d / unit).toList(), weeks, Colors.redAccent)),
      SectionCard(title: 'Weekly training load', child: _bars(load, weeks, Colors.orangeAccent)),
      if (eff.length >= 2)
        SectionCard(
          title: 'Efficiency (metres per heartbeat)',
          trailing: const HowButton(
              title: 'Efficiency',
              text: 'Distance divided by total heartbeats for each run. A rising line over weeks means you cover more ground '
                  'per beat: fitness is improving.'),
          child: SizedBox(
            height: 160,
            child: LineChart(LineChartData(
              gridData: const FlGridData(show: false),
              borderData: FlBorderData(show: false),
              titlesData: const FlTitlesData(
                topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              lineBarsData: [LineChartBarData(spots: eff, color: Colors.greenAccent, barWidth: 2)],
            )),
          ),
        ),
      if (AppState.I.profile.restingHr != null)
        SectionCard(
          title: 'Resting heart rate',
          child: Text('${AppState.I.profile.restingHr} BPM (${AppState.I.profile.restingHrSource})'),
        ),
      if (best.isNotEmpty)
        SectionCard(
          title: 'Personal bests',
          child: Column(children: [
            for (final k in bestEffortDistances.keys)
              if (best.containsKey(k))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(k),
                  subtitle: Text('${best[k]!.$2.start.day}/${best[k]!.$2.start.month}/${best[k]!.$2.start.year}'),
                  trailing: Text(fmtDuration(Duration(seconds: best[k]!.$1.round())),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
          ]),
        ),
    ]);
  }

  Widget _bars(List<double> values, List<DateTime> weeks, Color color) {
    final mx = values.fold<double>(0, math.max);
    return SizedBox(
      height: 150,
      child: BarChart(BarChartData(
        maxY: mx <= 0 ? 1 : mx * 1.15,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, meta) {
                final w = weeks[v.toInt()];
                return Text('${w.day}/${w.month}', style: const TextStyle(fontSize: 10));
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < values.length; i++)
            BarChartGroupData(x: i, barRods: [BarChartRodData(toY: values[i], color: color, width: 14)]),
        ],
      )),
    );
  }
}
