import 'package:flutter/painting.dart';

/// Five heart rate zones. With a resting HR they use heart rate reserve
/// (Karvonen); without one they use the same splits as a share of max HR.
class ZoneModel {
  const ZoneModel({required this.maxHr, this.restHr});

  final int maxHr;
  final int? restHr;

  static const bounds = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0];
  static const names = ['Below zones', 'Recovery', 'Endurance', 'Tempo', 'Threshold', 'Max'];
  static const feel = ['', 'Very easy', 'Easy, can chat', 'Steady, short sentences', 'Hard, a few words', 'All out'];

  bool get usesReserve => restHr != null && restHr! < maxHr;

  /// Share of reserve (or of max) for a BPM value.
  double fraction(num bpm) {
    if (usesReserve) return (bpm - restHr!) / (maxHr - restHr!);
    return bpm / maxHr;
  }

  int bpmAt(double p) {
    if (usesReserve) return (restHr! + p * (maxHr - restHr!)).round();
    return (p * maxHr).round();
  }

  /// 0 means below zone 1, 1–5 are the zones.
  int zoneOf(num bpm) {
    final p = fraction(bpm);
    if (p < bounds[0]) return 0;
    for (var z = 1; z <= 4; z++) {
      if (p < bounds[z]) return z;
    }
    return 5;
  }

  /// Lowest BPM of a zone (zone 0 starts at 0).
  int lowBpm(int zone) => zone <= 0 ? 0 : bpmAt(bounds[zone - 1]);

  /// Highest BPM of a zone.
  int highBpm(int zone) => zone >= 5 ? maxHr : bpmAt(bounds[zone]) - 1;

  /// The recovery level used for "ready for next set": top of zone 2.
  int get recoveryLevel => highBpm(2);

  /// Continuous position for charts: 1.0 at the bottom of zone 1, 2.0 at
  /// the bottom of zone 2, and so on.
  double zoneFloat(num bpm) {
    final p = fraction(bpm);
    return ((p - 0.5) / 0.1 + 1).clamp(0, 6).toDouble();
  }

  String describe() => usesReserve
      ? 'Heart rate reserve (Karvonen): resting $restHr, max $maxHr'
      : 'Share of max HR ($maxHr), because no resting HR is set';
}

/// Zone colours paired with numbers everywhere, so colour is never the only cue.
const zoneColors = <Color>[
  Color(0xFF8E8E93), // below zones
  Color(0xFF4FC3F7), // 1
  Color(0xFF66BB6A), // 2
  Color(0xFFFFCA28), // 3
  Color(0xFFFF7043), // 4
  Color(0xFFE53935), // 5
];

/// Suggested target zones for a distance (plan's pacing table).
(int low, int high) suggestedTargetZone(double distanceM, {bool firstTime = false}) {
  if (firstTime || distanceM > 21100) return (2, 3);
  if (distanceM < 3000) return (4, 4);
  if (distanceM <= 10000) return (3, 4);
  return (3, 3);
}
