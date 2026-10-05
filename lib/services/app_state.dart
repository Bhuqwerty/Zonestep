import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/profile.dart';
import 'ble_service.dart';
import 'db.dart';
import 'voice_service.dart';

/// App-wide state: the profile and the chosen device.
class AppState extends ChangeNotifier {
  AppState._();
  static final AppState I = AppState._();

  Profile profile = Profile();
  DeviceRecord? device;

  Future<void> load() async {
    await AppDb.open();
    profile = await AppDb.I.loadProfile();
    final devices = await AppDb.I.devices();
    device = devices.isEmpty ? null : devices.first;
    await VoiceService.I.init(profile.ttsLanguage);
    VoiceService.I.delivery = profile.delivery;
    BleService.I.init();
    final d = device;
    if (d != null && profile.onboarded) {
      // Remember the chosen device and reconnect to it automatically.
      BleService.I.connect(d.id, d.name);
    }
    notifyListeners();
  }

  Future<void> saveProfile() async {
    await AppDb.I.saveProfile(profile);
    VoiceService.I.delivery = profile.delivery;
    notifyListeners();
  }

  Future<void> setDevice(DeviceRecord d) async {
    d.lastUsed = DateTime.now();
    await AppDb.I.saveDevice(d);
    device = d;
    notifyListeners();
  }

  Future<void> forgetDevice() async {
    final d = device;
    if (d == null) return;
    await BleService.I.disconnect();
    await AppDb.I.deleteDevice(d.id);
    final rest = await AppDb.I.devices();
    device = rest.isEmpty ? null : rest.first;
    notifyListeners();
  }

  Future<void> wipe() async {
    await BleService.I.disconnect();
    await AppDb.deleteEverything();
    await AppDb.open();
    profile = Profile();
    device = null;
    notifyListeners();
  }
}
