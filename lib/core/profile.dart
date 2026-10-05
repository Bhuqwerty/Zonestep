import 'dart:convert';
import 'dart:math' as math;

import 'zones.dart';

enum Sex { male, female, unspecified }

enum Delivery { voice, vibration, both }

/// Everything the user tells us about themselves, plus where each number came
/// from so the settings screen can explain it.
class Profile {
  Profile({
    this.age,
    this.sex = Sex.unspecified,
    this.weightKg,
    this.maxHrValue,
    this.maxHrSource = 'tanaka',
    this.maxHrUpdated,
    this.restingHr,
    this.restingHrSource = 'none',
    this.restingHrUpdated,
    this.cautious = false,
    this.delivery = Delivery.both,
    this.metric = true,
    this.ttsLanguage = 'en-US',
    this.onboarded = false,
    this.readinessFlag = false,
    this.sweatRateLph,
    this.defaultCooldownSec = 45,
    this.autoPause = true,
    this.batteryHelpShown = false,
  });

  int? age;
  Sex sex;
  double? weightKg;

  /// Set when the user entered or measured max HR. Null means "estimate".
  int? maxHrValue;

  /// entered | measured | tanaka | cautious
  String maxHrSource;
  DateTime? maxHrUpdated;
  int? restingHr;

  /// entered | measured | none
  String restingHrSource;
  DateTime? restingHrUpdated;
  bool cautious;
  Delivery delivery;
  bool metric;
  String ttsLanguage;
  bool onboarded;
  bool readinessFlag;
  double? sweatRateLph;
  int defaultCooldownSec;
  bool autoPause;
  bool batteryHelpShown;

  /// Tanaka, Monahan, Seals 2001: 208 − 0.7 × age.
  static double tanaka(int age) => 208 - 0.7 * age;

  /// Fox: 220 − age.
  static double fox(int age) => 220.0 - age;

  int get maxHr {
    if (maxHrValue != null) return maxHrValue!;
    final a = age ?? 35;
    final t = tanaka(a);
    return (cautious ? math.min(t, fox(a)) : t).round();
  }

  String get maxHrExplanation {
    switch (maxHrSource) {
      case 'entered':
        return 'You entered this value.';
      case 'measured':
        return 'Measured from a clean reading during one of your sessions.';
      default:
        final a = age;
        if (a == null) {
          return 'Estimated for age 35 because no age was entered. Add your age for a better estimate.';
        }
        if (cautious) {
          return 'Cautious estimate: the lower of Tanaka (208 − 0.7 × $a = ${tanaka(a).toStringAsFixed(0)}) '
              'and 220 − $a = ${fox(a).toStringAsFixed(0)}. Age formulas miss a given person by about 9–11 BPM '
              'on average and up to about ±20 BPM.';
        }
        return 'Average estimate, Tanaka formula: 208 − 0.7 × $a = ${tanaka(a).toStringAsFixed(0)}. '
            'Age formulas miss a given person by about 9–11 BPM on average and up to about ±20 BPM.';
    }
  }

  ZoneModel get zones => ZoneModel(maxHr: maxHr, restHr: restingHr);

  bool get canEstimateCalories => age != null && weightKg != null;

  Map<String, dynamic> toJson() => {
        'age': age,
        'sex': sex.name,
        'weightKg': weightKg,
        'maxHrValue': maxHrValue,
        'maxHrSource': maxHrSource,
        'maxHrUpdated': maxHrUpdated?.toIso8601String(),
        'restingHr': restingHr,
        'restingHrSource': restingHrSource,
        'restingHrUpdated': restingHrUpdated?.toIso8601String(),
        'cautious': cautious,
        'delivery': delivery.name,
        'metric': metric,
        'ttsLanguage': ttsLanguage,
        'onboarded': onboarded,
        'readinessFlag': readinessFlag,
        'sweatRateLph': sweatRateLph,
        'defaultCooldownSec': defaultCooldownSec,
        'autoPause': autoPause,
        'batteryHelpShown': batteryHelpShown,
      };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        age: j['age'] as int?,
        sex: Sex.values.firstWhere((s) => s.name == j['sex'],
            orElse: () => Sex.unspecified),
        weightKg: (j['weightKg'] as num?)?.toDouble(),
        maxHrValue: j['maxHrValue'] as int?,
        maxHrSource: j['maxHrSource'] as String? ?? 'tanaka',
        maxHrUpdated: _date(j['maxHrUpdated']),
        restingHr: j['restingHr'] as int?,
        restingHrSource: j['restingHrSource'] as String? ?? 'none',
        restingHrUpdated: _date(j['restingHrUpdated']),
        cautious: j['cautious'] as bool? ?? false,
        delivery: Delivery.values.firstWhere((d) => d.name == j['delivery'],
            orElse: () => Delivery.both),
        metric: j['metric'] as bool? ?? true,
        ttsLanguage: j['ttsLanguage'] as String? ?? 'en-US',
        onboarded: j['onboarded'] as bool? ?? false,
        readinessFlag: j['readinessFlag'] as bool? ?? false,
        sweatRateLph: (j['sweatRateLph'] as num?)?.toDouble(),
        defaultCooldownSec: j['defaultCooldownSec'] as int? ?? 45,
        autoPause: j['autoPause'] as bool? ?? true,
        batteryHelpShown: j['batteryHelpShown'] as bool? ?? false,
      );

  String encode() => jsonEncode(toJson());
  static Profile decode(String s) =>
      Profile.fromJson(jsonDecode(s) as Map<String, dynamic>);

  static DateTime? _date(Object? v) =>
      v is String ? DateTime.tryParse(v) : null;
}
