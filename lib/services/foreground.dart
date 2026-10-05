import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

/// Keeps the process alive with the screen locked: a foreground service
/// with a persistent notification. The session logic itself runs in the
/// main isolate; the service only stops Android from killing it.
class ForegroundSession {
  static bool _initialised = false;

  static void init() {
    if (_initialised) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'zonestep_session',
        channelName: 'Active session',
        channelDescription: 'Shows heart rate while a session is running',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        // The session lives in the app's main isolate, so if the app is
        // swiped away the service must go with it rather than restart empty.
        stopWithTask: true,
        allowAutoRestart: false,
      ),
    );
    _initialised = true;
  }

  /// Returns false if Android refused to start the service.
  static Future<bool> start({required bool withLocation, required String text}) async {
    init();
    await Permission.notification.request();
    if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
    final r = await FlutterForegroundTask.startService(
      serviceTypes: [
        ForegroundServiceTypes.connectedDevice,
        if (withLocation) ForegroundServiceTypes.location,
      ],
      notificationTitle: 'Zonestep session running',
      notificationText: text,
    );
    return r is ServiceRequestSuccess;
  }

  static Future<void> update(String title, String text) async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
    }
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
  }

  static Future<bool> batteryOptimised() async => !(await FlutterForegroundTask.isIgnoringBatteryOptimizations);

  static Future<void> askBatteryExemption() async {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }
}
