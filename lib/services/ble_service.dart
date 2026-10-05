import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/hr_parser.dart';

final hrService = Uuid.parse('180D');
final hrMeasurement = Uuid.parse('2A37');
final bodyLocationChar = Uuid.parse('2A38');
final batteryService = Uuid.parse('180F');
final batteryLevel = Uuid.parse('2A19');

class TimedReading {
  TimedReading(this.at, this.reading);
  final DateTime at;
  final HrReading reading;
}

enum LinkState { idle, connecting, connected, reconnecting }

/// Talks to any standard BLE heart rate sensor (service 0x180D): chest
/// straps, arm bands, and watches in heart rate broadcast mode.
class BleService extends ChangeNotifier {
  BleService._();
  static final BleService I = BleService._();

  final _ble = FlutterReactiveBle();
  final _readings = StreamController<TimedReading>.broadcast();
  Stream<TimedReading> get readings => _readings.stream;

  BleStatus status = BleStatus.unknown;
  StreamSubscription<BleStatus>? _statusSub;

  final Map<String, DiscoveredDevice> found = {};
  StreamSubscription<DiscoveredDevice>? _scanSub;
  Timer? _scanTimer;
  bool scanning = false;
  String? scanError;

  String? deviceId;
  String? deviceName;
  LinkState link = LinkState.idle;
  bool _wanted = false;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _hrSub;
  Timer? _reconnectTimer;
  Timer? _batteryTimer;
  int _backoff = 1;

  int? battery;
  int? bodyLocation;
  TimedReading? last;
  bool everSawRr = false;
  bool? contactSupported;

  void init() {
    _statusSub ??= _ble.statusStream.listen((s) {
      status = s;
      notifyListeners();
    });
  }

  /// Bluetooth permissions. Android 12+ uses BLUETOOTH_SCAN (never for
  /// location) and BLUETOOTH_CONNECT; older versions need location to scan.
  Future<bool> ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    if (sdk < 31) {
      // Android 11 and older: Bluetooth scanning needs location.
      return (await Permission.locationWhenInUse.request()).isGranted;
    }
    final res = await [Permission.bluetoothScan, Permission.bluetoothConnect].request();
    return res.values.every((s) => s.isGranted);
  }

  Future<void> startScan() async {
    found.clear();
    scanError = null;
    if (!await ensurePermissions()) {
      scanError = 'Bluetooth permission was not granted. Allow "Nearby devices" for Zonestep in Android settings.';
      notifyListeners();
      return;
    }
    await _scanSub?.cancel();
    scanning = true;
    notifyListeners();
    _scanSub = _ble
        .scanForDevices(withServices: [hrService], scanMode: ScanMode.lowLatency, requireLocationServicesEnabled: false)
        .listen((d) {
      found[d.id] = d;
      notifyListeners();
    }, onError: (Object e) {
      scanError = 'Scan failed: $e';
      scanning = false;
      notifyListeners();
    });
    _scanTimer?.cancel();
    _scanTimer = Timer(const Duration(seconds: 20), stopScan);
  }

  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    scanning = false;
    notifyListeners();
  }

  bool get isConnected => link == LinkState.connected;

  /// Seconds since the last reading, or a large number if none.
  double get secondsSinceReading =>
      last == null ? 1e9 : DateTime.now().difference(last!.at).inMilliseconds / 1000;

  Future<void> connect(String id, String name) async {
    if (deviceId == id && _wanted && link != LinkState.idle) return;
    await disconnect();
    deviceId = id;
    deviceName = name;
    _wanted = true;
    everSawRr = false;
    contactSupported = null;
    battery = null;
    bodyLocation = null;
    _backoff = 1;
    _connect();
  }

  void _connect() {
    if (!_wanted || deviceId == null) return;
    link = link == LinkState.idle ? LinkState.connecting : LinkState.reconnecting;
    notifyListeners();
    _connSub?.cancel();
    _connSub = _ble
        .connectToDevice(id: deviceId!, connectionTimeout: const Duration(seconds: 15))
        .listen((u) async {
      switch (u.connectionState) {
        case DeviceConnectionState.connected:
          link = LinkState.connected;
          _backoff = 1;
          notifyListeners();
          await _onConnected();
        case DeviceConnectionState.disconnected:
          _onLost();
        default:
          break;
      }
    }, onError: (Object e) => _onLost());
  }

  Future<void> _onConnected() async {
    final id = deviceId!;
    try {
      await _ble.discoverAllServices(id);
    } catch (_) {}
    await _hrSub?.cancel();
    _hrSub = _ble
        .subscribeToCharacteristic(
            QualifiedCharacteristic(characteristicId: hrMeasurement, serviceId: hrService, deviceId: id))
        .listen((data) {
      final r = parseHeartRate(data);
      if (r == null) return;
      if (r.rrMs.isNotEmpty) everSawRr = true;
      contactSupported = r.contactSupported;
      last = TimedReading(DateTime.now(), r);
      _readings.add(last!);
      notifyListeners();
    }, onError: (Object e) => debugPrint('HR subscribe error: $e'));
    try {
      final loc = await _ble.readCharacteristic(
          QualifiedCharacteristic(characteristicId: bodyLocationChar, serviceId: hrService, deviceId: id));
      if (loc.isNotEmpty) bodyLocation = loc.first;
    } catch (_) {}
    await _readBattery();
    _batteryTimer?.cancel();
    _batteryTimer = Timer.periodic(const Duration(minutes: 5), (_) => _readBattery());
    try {
      await _ble.requestConnectionPriority(deviceId: id, priority: ConnectionPriority.balanced);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _readBattery() async {
    final id = deviceId;
    if (id == null || !isConnected) return;
    try {
      final b = await _ble.readCharacteristic(
          QualifiedCharacteristic(characteristicId: batteryLevel, serviceId: batteryService, deviceId: id));
      if (b.isNotEmpty) {
        battery = b.first;
        notifyListeners();
      }
    } catch (_) {}
  }

  void _onLost() {
    _hrSub?.cancel();
    _hrSub = null;
    _batteryTimer?.cancel();
    if (!_wanted) {
      link = LinkState.idle;
      notifyListeners();
      return;
    }
    link = LinkState.reconnecting;
    notifyListeners();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: _backoff), _connect);
    _backoff = (_backoff * 2).clamp(1, 10);
  }

  Future<void> disconnect() async {
    _wanted = false;
    _reconnectTimer?.cancel();
    _batteryTimer?.cancel();
    await _hrSub?.cancel();
    await _connSub?.cancel();
    _hrSub = null;
    _connSub = null;
    link = LinkState.idle;
    last = null;
    notifyListeners();
  }

  /// Guess strap vs watch from the body location and the name.
  static String guessKind(String name, int? bodyLocation, {bool? rr}) {
    if (bodyLocation == 2) return 'watch';
    if (bodyLocation == 1) return 'strap';
    final n = name.toLowerCase();
    const watchWords = [
      'forerunner', 'fenix', 'fēnix', 'venu', 'vivoactive', 'instinct', 'epix', 'enduro', 'edge',
      'vantage', 'grit', 'pacer', 'ignite', 'unite', 'polar m', 'coros', 'pace', 'apex', 'vertix',
      'suunto', 'race', 'amazfit', 'gtr', 'gts', 't-rex', 'cheetah', 'balance', 'watch',
    ];
    const strapWords = ['hrm', 'h10', 'h9', 'h7', 'tickr', 'kiprun', 'kalenji', 'decathlon', 'coospo', 'magene',
      'polar h', 'verity', 'oh1', 'rhythm', 'belt', 'strap', 'hw', 'h6', 'h808', 'heart'];
    if (strapWords.any(n.contains)) return 'strap';
    if (watchWords.any(n.contains)) return 'watch';
    if (rr == false) return 'watch';
    return 'strap';
  }
}
