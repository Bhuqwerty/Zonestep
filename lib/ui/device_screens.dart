import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../core/hr_parser.dart';
import '../core/models.dart';
import '../services/app_state.dart';
import '../services/ble_service.dart';
import '../services/foreground.dart';
import '../services/session_controller.dart';
import '../services/voice_service.dart';
import 'widgets.dart';

/// Lists nearby heart rate devices (service 0x180D only).
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.embedded = false, this.onTested});
  final bool embedded;
  final void Function(DeviceRecord)? onTested;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final ble = BleService.I;

  @override
  void initState() {
    super.initState();
    ble.startScan();
  }

  @override
  void dispose() {
    ble.stopScan();
    super.dispose();
  }

  Future<void> _pick(DiscoveredDevice d) async {
    await ble.stopScan();
    final name = d.name.isEmpty ? 'Heart rate sensor' : d.name;
    await ble.connect(d.id, name);
    if (!mounted) return;
    final rec = await Navigator.push<DeviceRecord>(
        context, MaterialPageRoute(builder: (_) => DeviceTestScreen(deviceId: d.id, name: name)));
    if (rec != null) {
      widget.onTested?.call(rec);
      if (!widget.embedded && mounted) Navigator.pop(context, rec);
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = ListenableBuilder(
      listenable: ble,
      builder: (context, _) {
        final list = ble.found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
        return ListView(
          shrinkWrap: widget.embedded,
          physics: widget.embedded ? const NeverScrollableScrollPhysics() : null,
          children: [
            if (ble.status == BleStatus.poweredOff)
              const ListTile(
                  leading: Icon(Icons.bluetooth_disabled), title: Text('Bluetooth is off. Turn it on to find your device.')),
            if (ble.scanError != null)
              ListTile(leading: const Icon(Icons.error_outline), title: Text(ble.scanError!)),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                  'Wet the strap\'s pads and put it on, or switch on heart rate broadcast on your watch '
                  '(Garmin: "Broadcast heart rate", Polar: "Share HR with other devices", Coros: "Heart rate broadcast", '
                  'Amazfit: "Heart rate push").'),
            ),
            for (final d in list)
              ListTile(
                leading: Icon(BleService.guessKind(d.name, null) == 'watch' ? Icons.watch : Icons.favorite),
                title: Text(d.name.isEmpty ? 'Unnamed heart rate sensor' : d.name),
                subtitle: Text('Signal ${d.rssi} dBm'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pick(d),
              ),
            if (list.isEmpty && ble.scanning)
              const ListTile(leading: CircularProgressIndicator(), title: Text('Searching for heart rate devices…')),
            if (!ble.scanning)
              Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton.icon(
                    onPressed: ble.startScan, icon: const Icon(Icons.refresh), label: const Text('Search again')),
              ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                  'Apple Watch and Wear OS watches are coming in a later version; use a chest strap meanwhile. '
                  'Fitbit and older Samsung watches are not supported, but a chest strap will work.',
                  style: TextStyle(fontSize: 12)),
            ),
          ],
        );
      },
    );
    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: const Text('Pair a device')), body: body);
  }
}

enum _Step { connect, still, response, lock, voice, done }

/// The 90-second device test from the plan, ending in a result card and a
/// "what this device can do" card.
class DeviceTestScreen extends StatefulWidget {
  const DeviceTestScreen({super.key, required this.deviceId, required this.name});
  final String deviceId;
  final String name;

  @override
  State<DeviceTestScreen> createState() => _DeviceTestScreenState();
}

class _DeviceTestScreenState extends State<DeviceTestScreen> with WidgetsBindingObserver {
  final ble = BleService.I;
  _Step step = _Step.connect;
  final Map<String, String> state = {
    'type': 'running',
    'signal': 'pending',
    'contact': 'pending',
    'plausible': 'pending',
    'response': 'pending',
    'rr': 'pending',
    'lock': 'pending',
    'voice': 'pending',
  };
  final Map<String, String> detail = {};
  StreamSubscription<TimedReading>? _sub;
  final List<TimedReading> _readings = [];
  Timer? _timer;
  int countdown = 0;
  bool _waitingUser = false;
  bool isWatch = false;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = ble.readings.listen((r) => _readings.add(r));
    _runConnect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _timer?.cancel();
    if (SessionController.active == null) ForegroundSession.stop();
    super.dispose();
  }

  void _set(String k, String v, [String? d]) {
    state[k] = v;
    if (d != null) detail[k] = d;
    if (mounted) setState(() {});
  }

  Future<void> _runConnect() async {
    for (var i = 0; i < 20; i++) {
      if (_readings.isNotEmpty) break;
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return;
    }
    if (_readings.isEmpty) {
      _set('type', 'fail',
          "This device isn't sending a standard heart rate signal. Supported: Bluetooth chest straps and arm bands "
          '(Decathlon, Polar, Garmin, Wahoo, Coospo, Magene) and watches with heart rate broadcast switched on.');
      step = _Step.done;
      setState(() {});
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    isWatch = BleService.guessKind(widget.name, ble.bodyLocation) == 'watch';
    final bits = <String>[
      widget.name,
      if (ble.battery != null) 'battery ${ble.battery}%',
      if (ble.bodyLocation != null) 'worn at: ${bodyLocationName(ble.bodyLocation)}',
    ];
    _set('type', 'pass', bits.join(' · '));
    setState(() {
      step = _Step.still;
      _waitingUser = true;
    });
  }

  void _startStill() {
    _waitingUser = false;
    _readings.clear();
    _set('signal', 'running', 'Sit still for 30 seconds.');
    _set('contact', 'running');
    _set('plausible', 'running');
    _countdown(30, () {
      final rs = List<TimedReading>.of(_readings);
      var maxGap = 0.0;
      for (var i = 1; i < rs.length; i++) {
        final g = rs[i].at.difference(rs[i - 1].at).inMilliseconds / 1000;
        if (g > maxGap) maxGap = g;
      }
      if (rs.length >= 25 && maxGap <= 3) {
        _set('signal', 'pass', '${rs.length} readings, longest gap ${maxGap.toStringAsFixed(1)} s.');
      } else if (rs.length >= 15) {
        _set('signal', 'warn',
            'Gaps up to ${maxGap.toStringAsFixed(0)} s. Move the phone closer and check the strap battery.');
      } else {
        _set('signal', 'fail', 'Only ${rs.length} readings in 30 s. Move the phone closer and check the strap battery.');
      }
      final supported = rs.any((r) => r.reading.contactSupported);
      if (!supported) {
        _set('contact', 'pass', 'This device does not report skin contact, which is normal for many watches.');
      } else {
        final ok = rs.where((r) => r.reading.hasContact).length / rs.length;
        _set(
            'contact',
            ok >= 0.9 ? 'pass' : 'fail',
            ok >= 0.9
                ? 'Good skin contact.'
                : "Contact dropped ${((1 - ok) * 100).round()}% of the time. Wet the strap's sensor pads and tighten it.");
      }
      final bpms = rs.map((r) => r.reading.bpm).toList();
      if (bpms.isEmpty) {
        _set('plausible', 'fail', 'No readings.');
      } else {
        final mn = bpms.reduce((a, b) => a < b ? a : b), mx = bpms.reduce((a, b) => a > b ? a : b);
        final inRange = mn >= 35 && mx <= 110;
        final varies = mx - mn >= 2;
        if (inRange && varies) {
          _set('plausible', 'pass', 'Resting reading $mn–$mx BPM.');
        } else if (!varies) {
          _set('plausible', 'fail', 'Reading looks stuck at $mn. Re-seat the strap or watch.');
        } else {
          _set('plausible', 'warn', 'Reading $mn–$mx BPM is outside the usual resting range. Re-seat the strap or watch.');
        }
      }
      setState(() {
        step = _Step.response;
        _waitingUser = true;
      });
    });
  }

  void _startResponse() {
    _waitingUser = false;
    final base = _readings.isEmpty
        ? 0
        : _readings.skip((_readings.length - 10).clamp(0, _readings.length)).map((r) => r.reading.bpm).reduce((a, b) => a + b) /
            _readings.skip((_readings.length - 10).clamp(0, _readings.length)).length;
    _readings.clear();
    _set('response', 'running', 'March or jog on the spot for 30 seconds.');
    unawaited(VoiceService.I.say('March or jog on the spot.'));
    _countdown(60, () {
      final mx = _readings.isEmpty ? 0 : _readings.map((r) => r.reading.bpm).reduce((a, b) => a > b ? a : b);
      if (mx >= base + 10) {
        _set('response', 'pass', 'Rose from ${base.round()} to $mx BPM.');
      } else {
        _set('response', 'fail',
            "The sensor isn't following your effort (${base.round()} to $mx BPM). Usually fit or contact.");
      }
      _set(
          'rr',
          ble.everSawRr ? 'pass' : 'warn',
          ble.everSawRr
              ? 'Beat timing available: HRV and recovery stats will be shown.'
              : 'Not a failure: HRV and some recovery stats will be hidden for this device.');
      setState(() {
        step = _Step.lock;
        _waitingUser = true;
      });
    }, earlyExit: () => _readings.isNotEmpty && _readings.map((r) => r.reading.bpm).reduce((a, b) => a > b ? a : b) >= base + 10 && countdown <= 30);
  }

  Future<void> _startLock() async {
    _waitingUser = false;
    // Never replace a running session's service (it may carry GPS).
    if (SessionController.active == null) {
      await ForegroundSession.start(withLocation: false, text: 'Device test: screen lock check');
    }
    _set('lock', 'running', 'Lock your phone now. Unlock it when you hear "test done" (about 30 seconds).');
    _readings.clear();
  }

  void _skipLock() {
    _waitingUser = false;
    _set('lock', 'warn', 'Skipped. Run the device test again from Settings to check this.');
    setState(() {
      step = _Step.voice;
      _waitingUser = true;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (step != _Step.lock || state['lock'] != 'running') return;
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      if (_pausedAt != null) return;
      _pausedAt = DateTime.now();
      _readings.clear();
      _timer?.cancel();
      _timer = Timer(const Duration(seconds: 30), () => VoiceService.I.say('Test done. You can unlock your phone.'));
    } else if (s == AppLifecycleState.resumed && _pausedAt != null) {
      _timer?.cancel();
      final secs = DateTime.now().difference(_pausedAt!).inSeconds;
      final rs = List<TimedReading>.of(_readings);
      var maxGap = 0.0;
      for (var i = 1; i < rs.length; i++) {
        final g = rs[i].at.difference(rs[i - 1].at).inMilliseconds / 1000;
        if (g > maxGap) maxGap = g;
      }
      _pausedAt = null;
      if (secs < 20) {
        _set('lock', 'running', 'That was only $secs s. Lock the phone again and wait for "test done".');
        return;
      }
      if (rs.length >= secs * 0.8 && maxGap <= 3) {
        _set('lock', 'pass', 'Readings kept arriving with the screen locked.');
      } else {
        _set('lock', 'fail',
            'Readings stopped with the screen locked (${rs.length} in $secs s). Allow Zonestep to run in the background.');
      }
      if (SessionController.active == null) ForegroundSession.stop();
      setState(() {
        step = _Step.voice;
        _waitingUser = true;
      });
    }
  }

  Future<void> _playVoice() async {
    _set('voice', 'running', 'Listen for a sample alert.');
    await VoiceService.I.alert('This is your Zonestep coach. Heart rate 150, now in zone 3.');
  }

  void _voiceResult(bool heard) {
    _set('voice', heard ? 'pass' : 'fail', heard ? 'Voice alerts work.' : 'Check the volume and your headphones.');
    setState(() => step = _Step.done);
  }

  void _countdown(int seconds, VoidCallback done, {bool Function()? earlyExit}) {
    countdown = seconds;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      countdown--;
      if (countdown <= 0 || (earlyExit?.call() ?? false)) {
        t.cancel();
        done();
      }
      if (mounted) setState(() {});
    });
  }

  String get result {
    if (state['type'] == 'fail' || state['signal'] == 'fail' || state['plausible'] == 'fail') return 'problem';
    if (state.values.any((v) => v == 'warn' || v == 'fail')) return 'limits';
    return 'ready';
  }

  Future<void> _save() async {
    final d = DeviceRecord(
      id: widget.deviceId,
      name: widget.name,
      kind: isWatch ? 'watch' : 'strap',
      lastBattery: ble.battery,
      bodyLocation: ble.bodyLocation == null ? null : bodyLocationName(ble.bodyLocation),
      testResult: result,
      testAt: DateTime.now(),
      rrSupported: ble.everSawRr,
      contactSupported: ble.contactSupported,
    )..testDetails = {for (final k in state.keys) k: {'state': state[k], 'detail': detail[k]}};
    await AppState.I.setDevice(d);
    if (mounted) Navigator.pop(context, d);
  }

  @override
  Widget build(BuildContext context) {
    final done = step == _Step.done;
    return Scaffold(
      appBar: AppBar(title: Text('Testing ${widget.name}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListenableBuilder(
            listenable: ble,
            builder: (_, __) => Row(children: [
              const Icon(Icons.favorite, color: Colors.redAccent),
              const SizedBox(width: 8),
              Text(ble.last == null ? '--' : '${ble.last!.reading.bpm}',
                  style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800)),
              const SizedBox(width: 6),
              const Text('BPM'),
              const Spacer(),
              if (countdown > 0 && !done && !_waitingUser) Text('$countdown s', style: const TextStyle(fontSize: 22)),
            ]),
          ),
          const SizedBox(height: 8),
          CheckLine(label: 'Device type', state: state['type']!, detail: detail['type']),
          CheckLine(label: 'Signal', state: state['signal']!, detail: detail['signal']),
          CheckLine(label: 'Skin contact', state: state['contact']!, detail: detail['contact']),
          CheckLine(label: 'Plausible reading', state: state['plausible']!, detail: detail['plausible']),
          CheckLine(label: 'Response to effort', state: state['response']!, detail: detail['response']),
          CheckLine(label: 'Beat timing (RR)', state: state['rr']!, detail: detail['rr']),
          CheckLine(label: 'Screen locked', state: state['lock']!, detail: detail['lock']),
          if (state['lock'] == 'fail')
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  onPressed: ForegroundSession.askBatteryExemption, child: const Text('Fix battery optimisation')),
            ),
          CheckLine(label: 'Voice', state: state['voice']!, detail: detail['voice']),
          const SizedBox(height: 12),
          if (state['type'] == 'pass')
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('This is a watch'),
              subtitle: const Text('Watches read at the wrist and get a "wrist reading" label.'),
              value: isWatch,
              onChanged: (v) => setState(() => isWatch = v),
            ),
          if (_waitingUser && step == _Step.still)
            FilledButton(onPressed: _startStill, child: const Text('Start: sit still for 30 s')),
          if (_waitingUser && step == _Step.response)
            FilledButton(onPressed: _startResponse, child: const Text('Start: march or jog on the spot')),
          if (_waitingUser && step == _Step.lock) ...[
            FilledButton(onPressed: _startLock, child: const Text('Start: lock the phone for 30 s')),
            TextButton(onPressed: _skipLock, child: const Text('Skip this check')),
          ],
          if (step == _Step.voice) ...[
            OutlinedButton.icon(onPressed: _playVoice, icon: const Icon(Icons.volume_up), label: const Text('Play sample alert')),
            Row(children: [
              Expanded(child: FilledButton(onPressed: () => _voiceResult(true), child: const Text('I heard it'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton(onPressed: () => _voiceResult(false), child: const Text("I didn't"))),
            ]),
          ],
          if (done) ...[
            ResultCard(result: result),
            DeviceLimitsCard(isWatch: isWatch, rr: ble.everSawRr),
            const SizedBox(height: 8),
            FilledButton(onPressed: _save, child: Text(result == 'problem' ? 'Save anyway' : 'Use this device')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ],
        ],
      ),
    );
  }
}

class ResultCard extends StatelessWidget {
  const ResultCard({super.key, required this.result});
  final String result;

  @override
  Widget build(BuildContext context) {
    final (title, color, text) = switch (result) {
      'ready' => ('Ready for alerts', Colors.green, 'Everything checked out.'),
      'limits' => ('Works with limits', Colors.amber, 'Usable, with the limits noted above.'),
      _ => ('Problem found', Colors.redAccent, 'Fix the failed checks above before relying on alerts.'),
    };
    return Card(
      color: color.withValues(alpha: 0.18),
      child: ListTile(
        leading: Icon(Icons.verified, color: color),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(text),
      ),
    );
  }
}

/// "What this device can do", in plain words.
class DeviceLimitsCard extends StatelessWidget {
  const DeviceLimitsCard({super.key, required this.isWatch, required this.rr});
  final bool isWatch;
  final bool rr;

  @override
  Widget build(BuildContext context) {
    final lines = isWatch
        ? [
            'Measured at the wrist: good for steady efforts, less reliable in intervals, sprints and cold weather.',
            if (!rr) 'HRV is not available from this watch.',
            'Broadcasting uses more of the watch\'s battery.',
            'Sessions recorded with it carry a small "wrist reading" label.',
          ]
        : [
            'Chest strap: best accuracy for alerts.',
            rr ? 'HRV is available because it sends beat timing.' : 'This strap does not send beat timing, so HRV is hidden.',
          ];
    return SectionCard(
      title: 'What this device can do',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('• $l'))],
      ),
    );
  }
}

/// 60-second sit-still resting heart rate measurement.
class RestingMeasureScreen extends StatefulWidget {
  const RestingMeasureScreen({super.key});

  @override
  State<RestingMeasureScreen> createState() => _RestingMeasureScreenState();
}

class _RestingMeasureScreenState extends State<RestingMeasureScreen> {
  final ble = BleService.I;
  final List<int> _bpm = [];
  StreamSubscription<TimedReading>? _sub;
  Timer? _timer;
  int left = 60;
  bool running = false;
  int? result;

  void _start() {
    _bpm.clear();
    running = true;
    left = 60;
    _sub = ble.readings.listen((r) {
      if (r.reading.hasContact) _bpm.add(r.reading.bpm);
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      left--;
      if (left <= 0) {
        t.cancel();
        _sub?.cancel();
        running = false;
        // Use the calmest 30 seconds: the second half.
        final tail = _bpm.skip(_bpm.length ~/ 2).toList();
        result = tail.isEmpty ? null : (tail.reduce((a, b) => a + b) / tail.length).round();
      }
      setState(() {});
    });
    setState(() {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _use() async {
    final p = AppState.I.profile;
    p.restingHr = result;
    p.restingHrSource = 'measured';
    p.restingHrUpdated = DateTime.now();
    await AppState.I.saveProfile();
    if (mounted) Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Measure resting HR')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Sit or lie still with the strap on for one minute. Best done lying down just after waking; '
                'averaging three mornings gives the most reliable number.'),
            const SizedBox(height: 24),
            ListenableBuilder(
              listenable: ble,
              builder: (_, __) => Text(
                ble.isConnected ? (ble.last == null ? 'Waiting for heart rate…' : '${ble.last!.reading.bpm} BPM') : 'Device not connected',
                style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            if (running) Text('$left s left', textAlign: TextAlign.center, style: const TextStyle(fontSize: 22)),
            if (!running && result == null)
              FilledButton(onPressed: ble.isConnected ? _start : null, child: const Text('Start 60 s measurement')),
            if (result != null) ...[
              Text('Resting heart rate: $result BPM', textAlign: TextAlign.center, style: const TextStyle(fontSize: 22)),
              const SizedBox(height: 12),
              FilledButton(onPressed: _use, child: const Text('Use it')),
              TextButton(onPressed: _start, child: const Text('Measure again')),
            ],
          ]),
        ),
      );
}
