import 'dart:async';
import 'dart:collection';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';

import '../core/profile.dart';

/// Speaks alerts over music (ducking it) and vibrates.
class VoiceService {
  VoiceService._();
  static final VoiceService I = VoiceService._();

  final _tts = FlutterTts();
  bool _ready = false;
  bool _speaking = false;
  final Queue<String> _queue = Queue();
  Delivery delivery = Delivery.both;

  Future<void> init(String language) async {
    if (!_ready) {
      await _tts.awaitSpeakCompletion(true);
      try {
        await _tts.setAudioAttributesForNavigation();
      } catch (_) {}
      _ready = true;
    }
    await setLanguage(language);
    await _tts.setSpeechRate(0.5);
  }

  Future<void> setLanguage(String language) async {
    try {
      final ok = await _tts.isLanguageAvailable(language);
      if (ok == true) await _tts.setLanguage(language);
    } catch (_) {}
  }

  Future<List<String>> languages() async {
    try {
      final l = await _tts.getLanguages;
      return (l as List).map((e) => e.toString()).toList()..sort();
    } catch (_) {
      return ['en-US', 'en-GB'];
    }
  }

  Future<void> alert(String text, {bool safety = false, bool vibrateOnly = false}) async {
    final voice = !vibrateOnly && delivery != Delivery.vibration;
    final buzz = vibrateOnly || delivery != Delivery.voice;
    if (buzz) await vibrate(safety: safety);
    if (voice) await say(text);
  }

  Future<void> vibrate({bool safety = false}) async {
    try {
      if (await Vibration.hasVibrator()) {
        await Vibration.vibrate(pattern: safety ? [0, 600, 200, 600, 200, 600] : [0, 250, 150, 250]);
      }
    } catch (_) {}
  }

  Future<void> say(String text) async {
    _queue.add(text);
    if (_speaking) return;
    _speaking = true;
    while (_queue.isNotEmpty) {
      final t = _queue.removeFirst();
      try {
        await _tts.speak(t, focus: true);
      } catch (_) {}
    }
    _speaking = false;
  }

  Future<void> stop() async {
    _queue.clear();
    await _tts.stop();
  }
}
