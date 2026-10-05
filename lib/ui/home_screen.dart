import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/plan.dart';
import '../services/app_state.dart';
import '../services/ble_service.dart';
import '../services/db.dart';
import '../services/foreground.dart';
import '../services/session_controller.dart';
import 'device_screens.dart';
import 'history_screen.dart';
import 'live_screen.dart';
import 'plan_editor.dart';
import 'session_setup.dart';
import 'settings_screen.dart';
import 'summary_screen.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<SessionRecord> recent = [];

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _batteryHelp());
  }

  Future<void> _load() async {
    final r = await AppDb.I.sessions(limit: 5);
    if (mounted) setState(() => recent = r);
  }

  /// One-time guide to exempt the app from battery optimisation, because
  /// Samsung, Xiaomi, OnePlus and Oppo battery savers kill services.
  Future<void> _batteryHelp() async {
    final p = AppState.I.profile;
    if (p.batteryHelpShown) return;
    if (!await ForegroundSession.batteryOptimised()) return;
    if (!mounted) return;
    p.batteryHelpShown = true;
    await AppState.I.saveProfile();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Keep sessions alive'),
        content: const Text('Some phones (Samsung, Xiaomi, OnePlus, Oppo and others) stop apps in the background to '
            'save battery, which would cut your session short with the screen locked. Allow Zonestep to run '
            'unrestricted. On Samsung also check Settings > Battery > Background usage limits and keep Zonestep out of '
            '"Sleeping apps".'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Later')),
          FilledButton(
              onPressed: () {
                Navigator.pop(c);
                ForegroundSession.askBatteryExemption();
              },
              child: const Text('Allow')),
        ],
      ),
    );
  }

  Future<void> _go(Widget w) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final active = SessionController.active;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zonestep'),
        actions: [
          IconButton(icon: const Icon(Icons.history), tooltip: 'History', onPressed: () => _go(const HistoryScreen())),
          IconButton(icon: const Icon(Icons.settings), tooltip: 'Settings', onPressed: () => _go(const SettingsScreen())),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            if (active != null)
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                color: Theme.of(context).colorScheme.primaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.directions_run),
                  title: const Text('Session in progress'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _go(LiveScreen(controller: active)),
                ),
              ),
            const _DeviceCard(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Expanded(
                  child: _BigButton(
                    icon: Icons.directions_run,
                    label: 'Run',
                    sub: 'GPS, distance goal, coaching',
                    onTap: () => _go(const RunSetupScreen()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _BigButton(
                    icon: Icons.favorite,
                    label: 'Heart rate only',
                    sub: 'Gym, cycling, HIIT, yoga',
                    onTap: () => _go(const HrSetupScreen()),
                  ),
                ),
              ]),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('Alert plans'),
              subtitle: const Text('Build and reuse plans for your regular sessions'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _go(const PlansScreen()),
            ),
            if (AppState.I.profile.readinessFlag)
              const ListTile(
                leading: Icon(Icons.info_outline, color: Colors.amber),
                title: Text('Consider checking with a doctor before hard efforts.'),
                dense: true,
              ),
            if (recent.isNotEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Recent', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            for (final s in recent) SessionTile(session: s, onTap: () => _go(SummaryScreen(sessionId: s.id!))),
          ],
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.icon, required this.label, required this.sub, required this.onTap});
  final IconData icon;
  final String label;
  final String sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, size: 36),
              const SizedBox(height: 12),
              Text(label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              Text(sub, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      );
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([BleService.I, AppState.I]),
        builder: (context, _) {
          final ble = BleService.I;
          final dev = AppState.I.device;
          if (dev == null) {
            return SectionCard(
              title: 'No device paired',
              child: FilledButton.icon(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ScanScreen())),
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Pair a strap or watch'),
              ),
            );
          }
          final status = switch (ble.link) {
            LinkState.connected => ble.last == null ? 'Connected, waiting for heart rate' : 'Connected',
            LinkState.connecting => 'Connecting…',
            LinkState.reconnecting => 'Reconnecting…',
            LinkState.idle => 'Not connected',
          };
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: ListTile(
              leading: Icon(dev.isWatch ? Icons.watch : Icons.favorite,
                  color: ble.isConnected ? Colors.redAccent : Theme.of(context).disabledColor),
              title: Text(dev.name),
              subtitle: Text([
                status,
                if (ble.battery != null) 'battery ${ble.battery}%',
                if (dev.isWatch) 'wrist reading',
              ].join(' · ')),
              trailing: ble.isConnected && ble.last != null && ble.secondsSinceReading < 5
                  ? Text('${ble.last!.reading.bpm}', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800))
                  : (ble.link == LinkState.idle
                      ? TextButton(onPressed: () => ble.connect(dev.id, dev.name), child: const Text('Connect'))
                      : null),
            ),
          );
        },
      );
}

class SessionTile extends StatelessWidget {
  const SessionTile({super.key, required this.session, this.onTap});
  final SessionRecord session;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = session.summary ?? {};
    final metric = AppState.I.profile.metric;
    final dist = (s['distanceM'] as num?)?.toDouble() ?? 0;
    final when = session.start;
    final date = '${when.day}/${when.month}/${when.year}';
    return ListTile(
      leading: Icon(session.kind == SessionKind.run ? Icons.directions_run : Icons.favorite),
      title: Text(session.kind == SessionKind.run && dist > 0
          ? '${fmtDistance(dist, metric: metric)} ${unitName(metric)} run'
          : session.activity),
      subtitle: Text([
        date,
        fmtDuration(Duration(seconds: ((s['movingS'] as num?) ?? 0).round())),
        if (s['avgHr'] != null) 'avg ${(s['avgHr'] as num).round()} BPM',
      ].join(' · ')),
      trailing: s['goalMet'] == true ? const Icon(Icons.flag, color: Colors.green) : null,
      onTap: onTap,
    );
  }
}
