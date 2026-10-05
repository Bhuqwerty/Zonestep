/// Parser for the Bluetooth Heart Rate Measurement characteristic (0x2A37).
///
/// The first byte is a flags field that says how the rest is laid out, so it
/// is read on every packet: never assume 8-bit BPM or that RR data exists.
class HrReading {
  HrReading({
    required this.bpm,
    required this.contactSupported,
    required this.contactDetected,
    required this.rrMs,
    this.energyKj,
  });

  final int bpm;

  /// True when the sensor reports skin-contact status at all.
  final bool contactSupported;

  /// Only meaningful when [contactSupported] is true.
  final bool contactDetected;

  /// Beat-to-beat intervals in milliseconds (converted from 1/1024 s).
  final List<double> rrMs;
  final int? energyKj;

  /// A reading the coach can trust: contact either unsupported or detected.
  bool get hasContact => !contactSupported || contactDetected;
}

HrReading? parseHeartRate(List<int> data) {
  if (data.isEmpty) return null;
  final flags = data[0];
  final is16 = flags & 0x01 != 0;
  final contactSupported = flags & 0x04 != 0;
  final contactDetected = flags & 0x02 != 0;
  final hasEnergy = flags & 0x08 != 0;
  final hasRr = flags & 0x10 != 0;

  var i = 1;
  int bpm;
  if (is16) {
    if (data.length < 3) return null;
    bpm = data[1] | (data[2] << 8);
    i = 3;
  } else {
    if (data.length < 2) return null;
    bpm = data[1];
    i = 2;
  }

  int? energy;
  if (hasEnergy) {
    if (data.length < i + 2) return null;
    energy = data[i] | (data[i + 1] << 8);
    i += 2;
  }

  final rr = <double>[];
  if (hasRr) {
    while (i + 1 < data.length) {
      final raw = data[i] | (data[i + 1] << 8);
      rr.add(raw * 1000.0 / 1024.0);
      i += 2;
    }
  }

  return HrReading(
    bpm: bpm,
    contactSupported: contactSupported,
    contactDetected: contactDetected,
    rrMs: rr,
    energyKj: energy,
  );
}

/// Body Sensor Location (0x2A38) values from the Bluetooth spec.
String bodyLocationName(int? v) {
  switch (v) {
    case 0:
      return 'Other';
    case 1:
      return 'Chest';
    case 2:
      return 'Wrist';
    case 3:
      return 'Finger';
    case 4:
      return 'Hand';
    case 5:
      return 'Ear lobe';
    case 6:
      return 'Foot';
    default:
      return 'Unknown';
  }
}
