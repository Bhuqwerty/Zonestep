import '../core/models.dart';

/// GPX and TCX exports with heart rate. [privacyM] hides that many metres
/// at the start and end of the route so a home address is never revealed.

int? _bpmAt(List<HrSample> hr, int tMs) {
  if (hr.isEmpty) return null;
  var lo = 0, hi = hr.length - 1;
  while (hi - lo > 1) {
    final m = (lo + hi) ~/ 2;
    if (hr[m].tMs <= tMs) {
      lo = m;
    } else {
      hi = m;
    }
  }
  return hr[lo].bpm;
}

List<GpsPoint> _trim(List<GpsPoint> gps, double privacyM) {
  if (privacyM <= 0 || gps.isEmpty) return gps;
  final total = gps.last.dist;
  return gps.where((g) => g.dist >= privacyM && g.dist <= total - privacyM).toList();
}

String _iso(DateTime t) => t.toUtc().toIso8601String();

String toGpx(SessionData d, {double privacyM = 0}) {
  final start = d.session.start;
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<gpx version="1.1" creator="Zonestep" xmlns="http://www.topografix.com/GPX/1/1" '
        'xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">')
    ..writeln('<metadata><time>${_iso(start)}</time></metadata>')
    ..writeln('<trk><name>Zonestep ${d.session.activity}</name><type>running</type><trkseg>');
  for (final g in _trim(d.gps, privacyM)) {
    final t = start.add(Duration(milliseconds: g.tMs));
    final hr = _bpmAt(d.hr, g.tMs);
    b.write('<trkpt lat="${g.lat}" lon="${g.lon}">');
    if (g.alt != null) b.write('<ele>${g.alt!.toStringAsFixed(1)}</ele>');
    b.write('<time>${_iso(t)}</time>');
    if (hr != null) b.write('<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>$hr</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>');
    b.writeln('</trkpt>');
  }
  b.writeln('</trkseg></trk></gpx>');
  return b.toString();
}

String toTcx(SessionData d, {double privacyM = 0}) {
  final s = d.session;
  final start = s.start;
  final sport = s.kind.name == 'run' ? 'Running' : 'Other';
  final summary = s.summary ?? {};
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">')
    ..writeln('<Activities><Activity Sport="$sport"><Id>${_iso(start)}</Id>')
    ..writeln('<Lap StartTime="${_iso(start)}">')
    ..writeln('<TotalTimeSeconds>${(summary['movingS'] as num? ?? 0).toStringAsFixed(0)}</TotalTimeSeconds>')
    ..writeln('<DistanceMeters>${(summary['distanceM'] as num? ?? 0).toStringAsFixed(1)}</DistanceMeters>')
    ..writeln('<Calories>${(summary['kcal'] as num? ?? 0).round()}</Calories>')
    ..writeln('<Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod><Track>');
  final gps = _trim(d.gps, privacyM);
  if (gps.isNotEmpty) {
    for (final g in gps) {
      final hr = _bpmAt(d.hr, g.tMs);
      b.write('<Trackpoint><Time>${_iso(start.add(Duration(milliseconds: g.tMs)))}</Time>'
          '<Position><LatitudeDegrees>${g.lat}</LatitudeDegrees><LongitudeDegrees>${g.lon}</LongitudeDegrees></Position>');
      if (g.alt != null) b.write('<AltitudeMeters>${g.alt!.toStringAsFixed(1)}</AltitudeMeters>');
      b.write('<DistanceMeters>${g.dist.toStringAsFixed(1)}</DistanceMeters>');
      if (hr != null) b.write('<HeartRateBpm><Value>$hr</Value></HeartRateBpm>');
      b.writeln('</Trackpoint>');
    }
  } else {
    for (final h in d.hr) {
      b.writeln('<Trackpoint><Time>${_iso(start.add(Duration(milliseconds: h.tMs)))}</Time>'
          '<HeartRateBpm><Value>${h.bpm}</Value></HeartRateBpm></Trackpoint>');
    }
  }
  b.writeln('</Track></Lap></Activity></Activities></TrainingCenterDatabase>');
  return b.toString();
}
