import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/profile.dart';
import '../core/zones.dart';
import '../services/app_state.dart';
import '../services/ble_service.dart';
import '../services/foreground.dart';
import '../services/voice_service.dart';
import 'device_screens.dart';
import 'onboarding.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Profile get p => AppState.I.profile;
  String version = '';
  List<String> languages = [];

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((i) => setState(() => version = '${i.version} (${i.buildNumber})'));
    VoiceService.I.languages().then((l) => setState(() => languages = l));
  }

  Future<void> _save() async {
    await AppState.I.saveProfile();
    setState(() {});
  }

  String _date(DateTime? d) => d == null ? '' : ' · ${d.day}/${d.month}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final z = p.zones;
    final dev = AppState.I.device;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        SectionCard(
          title: 'Your numbers',
          child: Column(children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Max HR: ${p.maxHr} BPM'),
              subtitle: Text('${switch (p.maxHrSource) {
                'entered' => 'Entered',
                'measured' => 'Measured',
                _ => p.cautious ? 'Cautious estimate' : 'Average estimate (Tanaka)',
              }}${_date(p.maxHrUpdated)}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                HowButton(title: 'Max HR', text: p.maxHrExplanation),
                IconButton(icon: const Icon(Icons.edit), onPressed: _editMax),
              ]),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Resting HR: ${p.restingHr == null ? 'not set' : '${p.restingHr} BPM'}'),
              subtitle: Text('${switch (p.restingHrSource) {
                'entered' => 'Entered',
                'measured' => 'Measured with your strap',
                _ => 'Zones use a share of max HR instead',
              }}${_date(p.restingHrUpdated)}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.monitor_heart_outlined),
                  tooltip: 'Measure',
                  onPressed: () async {
                    await Navigator.push(context, MaterialPageRoute(builder: (_) => const RestingMeasureScreen()));
                    setState(() {});
                  },
                ),
                IconButton(icon: const Icon(Icons.edit), onPressed: _editRest),
              ]),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Age: ${p.age ?? 'not set'}'),
              trailing: const Icon(Icons.edit),
              onTap: () async {
                final v = await askInt(context, 'Age', initial: p.age, suffix: 'years');
                if (v != null && v > 5 && v < 110) {
                  p.age = v;
                  await _save();
                }
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Weight: ${p.weightKg == null ? 'not set (calories hidden)' : '${p.weightKg} kg'}'),
              trailing: const Icon(Icons.edit),
              onTap: () async {
                final v = await askDouble(context, 'Weight', initial: p.weightKg, suffix: 'kg');
                if (v != null && v > 20 && v < 300) {
                  p.weightKg = v;
                  await _save();
                }
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Sex (for calories and load)'),
              trailing: DropdownButton<Sex>(
                value: p.sex,
                items: const [
                  DropdownMenuItem(value: Sex.male, child: Text('Male')),
                  DropdownMenuItem(value: Sex.female, child: Text('Female')),
                  DropdownMenuItem(value: Sex.unspecified, child: Text('Not set')),
                ],
                onChanged: (v) {
                  p.sex = v!;
                  _save();
                },
              ),
            ),
            if (p.sweatRateLph != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Sweat rate: ${p.sweatRateLph!.toStringAsFixed(2)} L per hour'),
                subtitle: const Text('From your sweat test; personalises water reminders'),
                trailing: IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      p.sweatRateLph = null;
                      _save();
                    }),
              ),
          ]),
        ),
        SectionCard(
          title: 'Zones',
          trailing: HowButton(
              title: 'Zones',
              text: '${z.describe()}.\n\nThe five-zone split is a widely used coaching convention. Its scientific anchor is '
                  'the ACSM intensity scale (Garber et al. 2011): moderate is 40–59% of heart rate reserve and vigorous '
                  'is 60–89%. Zones use heart rate reserve (Karvonen) when a resting HR is set.'),
          child: Column(children: [
            for (var i = 1; i <= 5; i++)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: ZoneBadge(i),
                title: Text('${ZoneModel.names[i]} · ${ZoneModel.feel[i]}'),
                trailing: Text('${z.lowBpm(i)}–${z.highBpm(i)}'),
              ),
          ]),
        ),
        SectionCard(
          title: 'Device',
          child: Column(children: [
            if (dev != null) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(dev.isWatch ? Icons.watch : Icons.favorite),
                title: Text(dev.name),
                subtitle: Text([
                  dev.isWatch ? 'Watch (wrist reading)' : 'Chest strap',
                  if (dev.testResult != null)
                    switch (dev.testResult) {
                      'ready' => 'Ready for alerts',
                      'limits' => 'Works with limits',
                      _ => 'Problem found',
                    },
                  if (dev.rrSupported == false) 'no HRV',
                ].join(' · ')),
              ),
              Wrap(spacing: 8, children: [
                OutlinedButton(
                  onPressed: () async {
                    await BleService.I.connect(dev.id, dev.name);
                    if (!context.mounted) return;
                    await Navigator.push(context,
                        MaterialPageRoute(builder: (_) => DeviceTestScreen(deviceId: dev.id, name: dev.name)));
                    setState(() {});
                  },
                  child: const Text('Run device test'),
                ),
                OutlinedButton(
                  onPressed: () async {
                    await AppState.I.forgetDevice();
                    setState(() {});
                  },
                  child: const Text('Forget'),
                ),
              ]),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.bluetooth_searching),
                label: Text(dev == null ? 'Pair a device' : 'Pair a different device'),
                onPressed: () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => const ScanScreen()));
                  setState(() {});
                },
              ),
            ),
          ]),
        ),
        SectionCard(
          title: 'Alerts',
          child: Column(children: [
            SegmentedButton<Delivery>(
              segments: const [
                ButtonSegment(value: Delivery.voice, label: Text('Voice')),
                ButtonSegment(value: Delivery.vibration, label: Text('Vibration')),
                ButtonSegment(value: Delivery.both, label: Text('Both')),
              ],
              selected: {p.delivery},
              onSelectionChanged: (s) {
                p.delivery = s.first;
                _save();
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Cooldown per alert type: ${p.defaultCooldownSec} s'),
              trailing: const Icon(Icons.edit),
              onTap: () async {
                final v = await askInt(context, 'Cooldown', initial: p.defaultCooldownSec, suffix: 's');
                if (v != null && v >= 10) {
                  p.defaultCooldownSec = v;
                  await _save();
                }
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Voice language'),
              trailing: DropdownButton<String>(
                value: languages.contains(p.ttsLanguage) ? p.ttsLanguage : null,
                items: [for (final l in languages) DropdownMenuItem(value: l, child: Text(l))],
                onChanged: (v) async {
                  p.ttsLanguage = v ?? 'en-US';
                  await VoiceService.I.setLanguage(p.ttsLanguage);
                  await _save();
                },
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Kilometres'),
              subtitle: const Text('Off for miles'),
              value: p.metric,
              onChanged: (v) {
                p.metric = v;
                _save();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-pause on runs'),
              value: p.autoPause,
              onChanged: (v) {
                p.autoPause = v;
                _save();
              },
            ),
          ]),
        ),
        SectionCard(
          title: 'Background',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('If sessions stop when the screen is locked, allow Zonestep to run without battery restrictions.'),
            TextButton(onPressed: ForegroundSession.askBatteryExemption, child: const Text('Battery optimisation settings')),
            const Text('Please do not swipe Zonestep away from recent apps during a session.', style: TextStyle(fontSize: 12)),
          ]),
        ),
        ListTile(
          leading: const Icon(Icons.help_outline),
          title: const Text('Supported devices'),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.menu_book_outlined),
          title: const Text('Science and sources'),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SourcesScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: const Text('Privacy'),
          subtitle: const Text('Your data stays on your phone, in an encrypted database. Map tiles for the route view are '
              'downloaded from OpenStreetMap; your route itself is never sent.'),
        ),
        ListTile(
          leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
          title: const Text('Delete everything'),
          subtitle: const Text('Wipes the database and its key'),
          onTap: _wipe,
        ),
        ListTile(title: const Text('Version'), subtitle: Text(version)),
        const SizedBox(height: 24),
      ]),
    );
  }

  Future<void> _editMax() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(title: const Text('Max HR'), children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(c, 'enter'), child: const Text('Enter a value')),
        SimpleDialogOption(onPressed: () => Navigator.pop(c, 'average'), child: const Text('Average estimate (Tanaka)')),
        SimpleDialogOption(onPressed: () => Navigator.pop(c, 'cautious'), child: const Text('Cautious estimate')),
      ]),
    );
    if (choice == null || !mounted) return;
    if (choice == 'enter') {
      final v = await askInt(context, 'Max HR', initial: p.maxHr, suffix: 'BPM');
      if (v == null || v < 100 || v > 230) return;
      p.maxHrValue = v;
      p.maxHrSource = 'entered';
    } else {
      p.maxHrValue = null;
      p.cautious = choice == 'cautious';
      p.maxHrSource = choice == 'cautious' ? 'cautious' : 'tanaka';
    }
    p.maxHrUpdated = DateTime.now();
    await _save();
  }

  Future<void> _editRest() async {
    final v = await askInt(context, 'Resting HR (blank to clear)', initial: p.restingHr, suffix: 'BPM');
    p.restingHr = v != null && v > 25 && v < 120 ? v : null;
    p.restingHrSource = p.restingHr == null ? 'none' : 'entered';
    p.restingHrUpdated = DateTime.now();
    await _save();
  }

  Future<void> _wipe() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete everything?'),
        content: const Text('All sessions, plans, devices and settings are erased from this phone. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete everything')),
        ],
      ),
    );
    if (ok != true) return;
    await AppState.I.wipe();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const OnboardingScreen()), (_) => false);
  }
}

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Supported devices')),
        body: ListView(padding: const EdgeInsets.all(16), children: const [
          Text('Any Bluetooth heart rate sensor using the standard Heart Rate Service works. A device not listed here '
              'can still pass the device test and be used.'),
          SizedBox(height: 16),
          Text('Chest straps and arm bands', style: TextStyle(fontWeight: FontWeight.bold)),
          Text('Decathlon Kiprun / Kalenji Bluetooth and Dual belts, Polar H9 / H10 / Verity Sense / OH1, Garmin HRM-Dual / '
              'HRM-Pro / HRM 600, Wahoo TICKR, Coospo, Magene.'),
          SizedBox(height: 16),
          Text('Watches in broadcast mode', style: TextStyle(fontWeight: FontWeight.bold)),
          Text('Garmin: "Broadcast heart rate" (Forerunner, Fenix, Venu, Instinct and others).\n'
              'Polar: "Share HR with other devices" (Vantage, Grit X, Pacer, Ignite and others).\n'
              'Coros: "Heart rate broadcast".\n'
              'Suunto: recent models such as Race 2 and Vertical 2.\n'
              'Amazfit: "Heart rate push" on many models.\n\n'
              'Not every model in a brand supports broadcast. Watches read at the wrist: good for steady efforts, less reliable in '
              'intervals, sprints and cold weather. Most watches do not send beat timing, so HRV is hidden. Broadcasting drains '
              'the watch battery faster.'),
          SizedBox(height: 16),
          Text('Coming later', style: TextStyle(fontWeight: FontWeight.bold)),
          Text('Apple Watch and Wear OS (Galaxy Watch 4+, Pixel Watch) need small companion apps, planned for a later version. '
              'Use a chest strap meanwhile.'),
          SizedBox(height: 16),
          Text('Not supported', style: TextStyle(fontWeight: FontWeight.bold)),
          Text('Most Fitbit trackers and older Samsung (Tizen) watches do not share live heart rate. A chest strap will work. '
              'ANT+ is not supported.'),
        ]),
      );
}

class SourcesScreen extends StatelessWidget {
  const SourcesScreen({super.key});

  static const sources = [
    ('Max HR, Average', 'Tanaka, Monahan, Seals 2001, J Am Coll Cardiol: 208 − 0.7 × age'),
    ('Max HR error, Cautious', 'Martin et al. 2025, PLOS One: accuracy of age-based max HR equations'),
    ('Heart rate reserve zones', 'Karvonen, Kentala, Mustala 1957, Ann Med Exp Biol Fenn'),
    ('Intensity bands', 'Garber et al. 2011, ACSM position stand, Med Sci Sports Exerc 43(7)'),
    ('Calories from heart rate', 'Keytel et al. 2005, J Sports Sci 23(3)'),
    ('Calories from speed', "ACSM's Guidelines for Exercise Testing and Prescription, running equation"),
    ('Carbs per hour', 'Jeukendrup 2014, Sports Med'),
    ('Carbs, fluid loss, sodium', 'Thomas, Erdman, Burke 2016, ACSM/AND/DC joint position, Med Sci Sports Exerc 48(3)'),
    ('Water range, sweat test', 'Sawka et al. 2007, ACSM position stand, Med Sci Sports Exerc 39(2)'),
    ('Drink to thirst', 'Hew-Butler et al. 2015, hyponatremia consensus'),
    ('Heart rate recovery', 'Cole et al. 1999, N Engl J Med 341'),
    ('Training load (TRIMP)', 'Banister TRIMP, Morton, Fitz-Clarke, Banister 1990, J Appl Physiol'),
    ('HRV (RMSSD)', 'Task Force of the ESC and NASPE 1996, Circulation'),
    ('Cardiac drift', 'Coyle and González-Alonso 2001, Exerc Sport Sci Rev'),
    ('Readiness questions', 'PAR-Q+ (Warburton et al.)'),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Science and sources')),
        body: ListView(children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Every formula traces to a published source. Timing numbers (10 s holds, 2 BPM buffer, 45 s cooldowns, '
                '5% drift, 25% calorie disagreement, sip sizes) are product choices tuned in testing, not science. '
                'Zonestep gives fitness guidance, not medical advice.'),
          ),
          for (final s in sources) ListTile(title: Text(s.$1), subtitle: Text(s.$2)),
        ]),
      );
}
