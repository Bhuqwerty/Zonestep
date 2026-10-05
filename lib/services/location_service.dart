import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../core/formulas.dart';
import '../core/models.dart';

/// GPS distance with jitter filtering and auto-pause.
class LocationTracker {
  LocationTracker({this.ultra = false, this.autoPause = true});

  final bool ultra;
  final bool autoPause;

  StreamSubscription<Position>? _sub;
  Position? _last;
  double distance = 0;
  bool moving = true;
  double? speed;
  double? accuracy;
  DateTime? _slowSince;
  DateTime? lastFix;
  final _points = StreamController<GpsPoint>.broadcast();
  Stream<GpsPoint> get points => _points.stream;
  DateTime? _start;

  static Future<String?> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Location is switched off. Turn it on in quick settings to record distance.';
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
      return 'Location permission was not granted, so distance and pace cannot be recorded.';
    }
    return null;
  }

  void start(DateTime sessionStart) {
    _start = sessionStart;
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: ultra ? 5 : 2,
      intervalDuration: Duration(seconds: ultra ? 4 : 1),
    );
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_onPosition);
  }

  void _onPosition(Position p) {
    lastFix = DateTime.now();
    accuracy = p.accuracy;
    speed = p.speed >= 0 ? p.speed : null;
    if (p.accuracy > 30) return; // too noisy to trust
    final prev = _last;
    if (prev != null) {
      final d = haversine(prev.latitude, prev.longitude, p.latitude, p.longitude);
      final dt = p.timestamp.difference(prev.timestamp).inMilliseconds / 1000;
      final v = dt > 0 ? d / dt : 0;
      // Ignore jumps faster than 12 m/s and sub-metre wobble while standing.
      if (v < 12 && d > 0.8) {
        if (moving || !autoPause) distance += d;
      } else if (v >= 12) {
        return;
      }
    }
    _last = p;

    if (autoPause) {
      final s = speed ?? 0;
      if (s < 0.5) {
        _slowSince ??= DateTime.now();
        if (DateTime.now().difference(_slowSince!).inSeconds >= 6) moving = false;
      } else {
        _slowSince = null;
        moving = true;
      }
    }

    _points.add(GpsPoint(
      tMs: DateTime.now().difference(_start!).inMilliseconds,
      lat: p.latitude,
      lon: p.longitude,
      alt: p.altitude,
      acc: p.accuracy,
      dist: distance,
      moving: moving,
    ));
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}
