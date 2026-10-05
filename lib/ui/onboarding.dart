import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/profile.dart';
import '../services/app_state.dart';
import '../services/voice_service.dart';
import 'device_screens.dart';
import 'home_screen.dart';
import 'widgets.dart';

/// Six short, skippable screens: welcome, readiness, about you, your heart,
/// pair and test, alert preferences.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _page = PageController();
  int index = 0;
  Profile get p => AppState.I.profile;
  final readiness = List<bool?>.filled(_parq.length, null);
  final _age = TextEditingController();
  final _weight = TextEditingController();
  final _max = TextEditingController();
  final _rest = TextEditingController();
  String maxChoice = 'estimate';
  String restChoice = 'skip';
  DeviceRecord? tested;
  List<String> languages = [];

  static const _parq = [
    'Has a doctor ever said you have a heart condition or high blood pressure?',
    'Do you feel pain in your chest at rest, during daily activities, or when you exercise?',
    'Do you lose balance because of dizziness, or have you lost consciousness in the last 12 months?',
    'Have you been diagnosed with another chronic medical condition (other than heart disease or high blood pressure)?',
    'Are you currently taking medication for a chronic medical condition?',
    'Do you have a bone, joint or soft tissue problem that could be made worse by being more active?',
    'Has a doctor ever said you should only do medically supervised physical activity?',
  ];

  @override
  void initState() {
    super.initState();
    VoiceService.I.languages().then((l) => setState(() => languages = l));
  }

  void _next() {
    FocusScope.of(context).unfocus();
    if (index == 2) _saveAbout();
    if (index == 3) _saveHeart();
    if (index < 5) {
      _page.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    } else {
      _finish();
    }
  }

  void _saveAbout() {
    p.age = int.tryParse(_age.text.trim());
    p.weightKg = double.tryParse(_weight.text.trim().replaceAll(',', '.'));
  }

  void _saveHeart() {
    if (maxChoice == 'know') {
      final v = int.tryParse(_max.text.trim());
      if (v != null && v > 100 && v < 230) {
        p.maxHrValue = v;
        p.maxHrSource = 'entered';
        p.maxHrUpdated = DateTime.now();
      }
    } else {
      p.maxHrValue = null;
      p.maxHrSource = p.cautious ? 'cautious' : 'tanaka';
    }
    if (restChoice == 'know') {
      final v = int.tryParse(_rest.text.trim());
      if (v != null && v > 25 && v < 120) {
        p.restingHr = v;
        p.restingHrSource = 'entered';
        p.restingHrUpdated = DateTime.now();
      }
    }
  }

  Future<void> _finish() async {
    p.readinessFlag = readiness.any((r) => r == true);
    p.onboarded = true;
    await AppState.I.saveProfile();
    await VoiceService.I.setLanguage(p.ttsLanguage);
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [_welcome(), _readiness(), _about(), _heart(), _pair(), _alerts()];
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          LinearProgressIndicator(value: (index + 1) / pages.length),
          Expanded(
            child: PageView(
              controller: _page,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) => setState(() => index = i),
              children: pages,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              if (index > 0)
                TextButton(
                    onPressed: () => _page.previousPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
                    child: const Text('Back')),
              const Spacer(),
              if (index > 0 && index < 5) TextButton(onPressed: _next, child: const Text('Skip')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _next, child: Text(index == 5 ? 'Done' : 'Next')),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _wrap(String title, List<Widget> children) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          ...children,
        ],
      );

  Widget _welcome() => _wrap('Welcome to Zonestep', [
        const Icon(Icons.favorite, size: 72, color: Colors.redAccent),
        const SizedBox(height: 16),
        const Text('A heart rate coach that talks to you while you run or train, using any standard Bluetooth heart '
            'rate strap or a watch in broadcast mode.'),
        const SizedBox(height: 16),
        const ListTile(
          leading: Icon(Icons.lock),
          title: Text('Your data stays on your phone'),
          subtitle: Text('No account, no server, no analytics. Everything is stored in an encrypted database on this phone.'),
        ),
        const ListTile(
          leading: Icon(Icons.medical_information_outlined),
          title: Text('Fitness guidance, not medical advice'),
          subtitle: Text('Zonestep estimates zones and calories with published formulas. It cannot diagnose anything. '
              'If you feel unwell during exercise, stop and get help.'),
        ),
        const SizedBox(height: 8),
        const Text('Setup takes about three minutes and every step can be skipped.'),
      ]);

  Widget _readiness() => _wrap('Readiness check', [
        const Text('A few yes/no questions modelled on the PAR-Q+. A "yes" doesn\'t block anything; it means it\'s worth '
            'checking with a doctor before hard efforts.'),
        const SizedBox(height: 8),
        for (var i = 0; i < _parq.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_parq[i]),
              SegmentedButton<bool>(
                emptySelectionAllowed: true,
                segments: const [ButtonSegment(value: false, label: Text('No')), ButtonSegment(value: true, label: Text('Yes'))],
                selected: readiness[i] == null ? {} : {readiness[i]!},
                onSelectionChanged: (s) => setState(() => readiness[i] = s.isEmpty ? null : s.first),
              ),
            ]),
          ),
        if (readiness.any((r) => r == true))
          const Card(
            child: ListTile(
              leading: Icon(Icons.info, color: Colors.amber),
              title: Text('Consider checking with a doctor before hard efforts.'),
              subtitle: Text('You can still use every feature. Cautious max HR (next screens) keeps alerts lower.'),
            ),
          ),
      ]);

  Widget _about() => _wrap('About you', [
        const Text('Age drives your max heart rate estimate. Sex and weight are only used for calories and training '
            'load, and are optional.'),
        const SizedBox(height: 16),
        TextField(controller: _age, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Age', suffixText: 'years')),
        const SizedBox(height: 12),
        DropdownButtonFormField<Sex>(
          initialValue: p.sex,
          decoration: const InputDecoration(labelText: 'Sex (for calorie and load formulas)'),
          items: const [
            DropdownMenuItem(value: Sex.male, child: Text('Male')),
            DropdownMenuItem(value: Sex.female, child: Text('Female')),
            DropdownMenuItem(value: Sex.unspecified, child: Text('Prefer not to say')),
          ],
          onChanged: (v) => setState(() => p.sex = v ?? Sex.unspecified),
        ),
        const SizedBox(height: 12),
        TextField(
            controller: _weight,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Weight', suffixText: 'kg')),
        const SizedBox(height: 8),
        const Text('Without weight, calories stay hidden rather than guessed.', style: TextStyle(fontSize: 12)),
      ]);

  Widget _heart() {
    final age = int.tryParse(_age.text.trim());
    final tanaka = age == null ? null : Profile.tanaka(age).round();
    final cautious = age == null ? null : [Profile.tanaka(age), Profile.fox(age)].reduce((a, b) => a < b ? a : b).round();
    return _wrap('Your heart', [
      Text('Max heart rate', style: Theme.of(context).textTheme.titleMedium),
      RadioGroup<String>(
        groupValue: maxChoice,
        onChanged: (v) => setState(() => maxChoice = v!),
        child: const Column(children: [
          RadioListTile(value: 'know', title: Text('I know it')),
          RadioListTile(
              value: 'measure',
              title: Text('Measure it'),
              subtitle: Text('Zonestep spots a higher clean reading during a hard session and offers to use it.')),
          RadioListTile(value: 'estimate', title: Text('Estimate for me')),
        ]),
      ),
      if (maxChoice == 'know')
        TextField(controller: _max, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Max HR', suffixText: 'BPM')),
      if (maxChoice != 'know') ...[
        SwitchListTile(
          title: Text('Cautious estimate${cautious != null ? ' ($cautious BPM)' : ''}'),
          subtitle: Text('Average (Tanaka 208 − 0.7 × age)${tanaka != null ? ' = $tanaka BPM' : ''}. Cautious takes the lower of '
              'Tanaka and 220 − age so zones and alerts sit lower. Good for beginners and older runners.'),
          value: p.cautious,
          onChanged: (v) => setState(() => p.cautious = v),
        ),
        const Text('Age formulas miss a given person by about 9–11 BPM on average, up to about ±20 BPM.',
            style: TextStyle(fontSize: 12)),
      ],
      const Divider(height: 32),
      Text('Resting heart rate', style: Theme.of(context).textTheme.titleMedium),
      RadioGroup<String>(
        groupValue: restChoice,
        onChanged: (v) => setState(() => restChoice = v!),
        child: const Column(children: [
          RadioListTile(value: 'know', title: Text('I know it')),
          RadioListTile(value: 'measure', title: Text('Measure it'), subtitle: Text('A 60-second sit-still reading after pairing.')),
          RadioListTile(
              value: 'skip',
              title: Text('Estimate for me'),
              subtitle: Text('Zones then use a share of max HR instead of heart rate reserve.')),
        ]),
      ),
      if (restChoice == 'know')
        TextField(controller: _rest, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Resting HR', suffixText: 'BPM')),
    ]);
  }

  Widget _pair() => _wrap('Pair and test your device', [
        if (tested != null) ...[
          ResultCard(result: tested!.testResult ?? 'limits'),
          DeviceLimitsCard(isWatch: tested!.isWatch, rr: tested!.rrSupported ?? false),
          if (restChoice == 'measure' && p.restingHr == null)
            FilledButton(
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const RestingMeasureScreen()));
                setState(() {});
              },
              child: const Text('Measure resting HR now'),
            ),
          if (p.restingHr != null) Text('Resting HR: ${p.restingHr} BPM'),
          TextButton(onPressed: () => setState(() => tested = null), child: const Text('Pair a different device')),
        ] else
          ScanScreen(embedded: true, onTested: (d) => setState(() => tested = d)),
      ]);

  Widget _alerts() => _wrap('How you like alerts', [
        Text('Delivery', style: Theme.of(context).textTheme.titleMedium),
        SegmentedButton<Delivery>(
          segments: const [
            ButtonSegment(value: Delivery.voice, label: Text('Voice')),
            ButtonSegment(value: Delivery.vibration, label: Text('Vibration')),
            ButtonSegment(value: Delivery.both, label: Text('Both')),
          ],
          selected: {p.delivery},
          onSelectionChanged: (s) => setState(() => p.delivery = s.first),
        ),
        const SizedBox(height: 16),
        Text('Units', style: Theme.of(context).textTheme.titleMedium),
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: true, label: Text('Kilometres')), ButtonSegment(value: false, label: Text('Miles'))],
          selected: {p.metric},
          onSelectionChanged: (s) => setState(() => p.metric = s.first),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: languages.contains(p.ttsLanguage) ? p.ttsLanguage : null,
          decoration: const InputDecoration(labelText: 'Voice language'),
          items: [for (final l in languages) DropdownMenuItem(value: l, child: Text(l))],
          onChanged: (v) => setState(() => p.ttsLanguage = v ?? 'en-US'),
        ),
        const SizedBox(height: 8),
        const Text('Alert text is in English; the voice language changes the accent.', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () async {
            await VoiceService.I.setLanguage(p.ttsLanguage);
            VoiceService.I.delivery = p.delivery;
            await VoiceService.I.alert('Kilometre 3, 5 42 pace, average heart rate 158.');
          },
          icon: const Icon(Icons.volume_up),
          label: const Text('Try it'),
        ),
        const SizedBox(height: 8),
        HowButton(
            title: 'Alerts over music',
            text: 'Voice alerts lower your music briefly (ducking) and then let it continue, so Spotify or YouTube Music '
                'keep playing.'),
      ]);
}
