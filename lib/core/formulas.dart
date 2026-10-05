import 'dart:math' as math;

import 'profile.dart';

/// Keytel et al. 2005, energy expenditure from heart rate without a VO2max
/// test. Returns kcal per minute (never negative). Unknown sex averages the
/// male and female equations.
double keytelKcalPerMin({
  required double bpm,
  required int age,
  required double weightKg,
  required Sex sex,
}) {
  double male() =>
      -55.0969 + 0.6309 * bpm + 0.1988 * weightKg + 0.2017 * age;
  double female() =>
      -20.4022 + 0.4472 * bpm - 0.1263 * weightKg + 0.074 * age;
  final kj = switch (sex) {
    Sex.male => male(),
    Sex.female => female(),
    Sex.unspecified => (male() + female()) / 2,
  };
  return math.max(0, kj / 4.184);
}

/// ACSM metabolic equation for running: VO2 = 0.2·v + 0.9·v·grade + 3.5
/// (ml/kg/min, v in m/min). Converted at about 5 kcal per litre of oxygen.
double acsmRunningKcalPerMin({
  required double speedMps,
  required double grade,
  required double weightKg,
}) {
  final v = speedMps * 60;
  final vo2 = 0.2 * v + 0.9 * v * math.max(grade, 0) + 3.5;
  return vo2 * weightKg / 1000 * 5;
}

/// Banister TRIMP for a slice of time. [hrr] is the fraction of heart rate
/// reserve (0–1).
double trimpSlice({required double minutes, required double hrr, required Sex sex}) {
  final x = hrr.clamp(0.0, 1.0);
  final k = sex == Sex.female ? 1.67 : 1.92;
  final a = sex == Sex.female ? 0.86 : 0.64;
  return minutes * x * a * math.exp(k * x);
}

/// RMSSD over RR intervals in ms, after dropping implausible beats and
/// jumps of more than 20% from the previous beat. Null if too few beats.
double? rmssd(List<double> rr, {int minBeats = 60}) {
  final clean = <double>[];
  for (final r in rr) {
    if (r < 300 || r > 2000) continue;
    if (clean.isNotEmpty && (r - clean.last).abs() > clean.last * 0.2) continue;
    clean.add(r);
  }
  if (clean.length < minBeats) return null;
  var sum = 0.0;
  for (var i = 1; i < clean.length; i++) {
    final d = clean[i] - clean[i - 1];
    sum += d * d;
  }
  return math.sqrt(sum / (clean.length - 1));
}

/// Carbohydrate target in grams per hour by expected duration
/// (Jeukendrup 2014; ACSM/AND/DC 2016).
({double gPerHour, String note}) carbTarget(Duration expected) {
  final m = expected.inMinutes;
  if (m < 45) return (gPerHour: 0, note: 'Under 45 minutes: no carbs needed.');
  if (m < 75) {
    return (gPerHour: 0, note: '45–75 minutes: small amounts or a mouth rinse. One optional reminder.');
  }
  if (m < 120) return (gPerHour: 30, note: '1–2 hours: about 30 g per hour.');
  if (m < 150) return (gPerHour: 60, note: '2–2.5 hours: up to 60 g per hour.');
  return (
    gPerHour: 90,
    note: 'Over 2.5 hours: up to 90 g per hour with glucose plus fructose mixes. Practise this in training first.'
  );
}

/// Minutes between carb reminders, from serving size and the hourly target.
int? carbIntervalMin(Duration expected, double servingG) {
  final t = carbTarget(expected);
  if (t.gPerHour <= 0 || servingG <= 0) return null;
  return (servingG / t.gPerHour * 60).round().clamp(10, 90);
}

/// Water reminder plan (ACSM 2007; hyponatremia consensus 2015): drink to
/// thirst, about 0.4–0.8 L per hour, small sips every 15–20 minutes.
({int intervalMin, int sipMl, bool electrolytes}) waterPlan({
  required Duration expected,
  double? sweatRateLph,
  bool hotDay = false,
}) {
  // A measured sweat rate personalises the amount, but never past the top of
  // the guideline range, so reminders don't push overdrinking.
  final base = sweatRateLph ?? (hotDay ? 0.7 : 0.5);
  final lph = (hotDay ? math.max(base, 0.7) : base).clamp(0.4, 0.8);
  final interval = hotDay ? 15 : 20;
  final sip = (lph * 1000 * interval / 60 / 10).round() * 10;
  final electrolytes = expected.inMinutes > 120 || (sweatRateLph ?? 0) > 1.2;
  return (intervalMin: interval, sipMl: sip, electrolytes: electrolytes);
}

/// Sweat rate in L per hour from a before/after weigh-in.
double sweatRate({
  required double weightBeforeKg,
  required double weightAfterKg,
  required double drankL,
  required Duration duration,
}) {
  final hours = duration.inSeconds / 3600;
  if (hours <= 0) return 0;
  return math.max(0, (weightBeforeKg - weightAfterKg + drankL) / hours);
}

/// Haversine distance in metres.
double haversine(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

double _rad(double d) => d * math.pi / 180;
