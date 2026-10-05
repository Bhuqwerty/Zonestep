import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'services/app_state.dart';
import 'services/foreground.dart';
import 'services/session_controller.dart';
import 'ui/home_screen.dart';
import 'ui/onboarding.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  ForegroundSession.init();
  Object? startupError;
  try {
    await AppState.I.load();
    await recoverUnfinished(AppState.I.profile);
  } catch (e) {
    startupError = e;
  }
  runApp(ZonestepApp(startupError: startupError));
}

class ZonestepApp extends StatelessWidget {
  const ZonestepApp({super.key, this.startupError});
  final Object? startupError;

  ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE53935), brightness: b),
      );

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Zonestep',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: ThemeMode.system,
        home: WithForegroundTask(
          child: startupError != null
              ? Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Zonestep could not open its database: $startupError'))))
              : (AppState.I.profile.onboarded ? const HomeScreen() : const OnboardingScreen()),
        ),
      );
}
