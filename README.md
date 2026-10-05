# Zonestep

A heart rate coach for runners and gym sessions. It reads any standard Bluetooth heart rate strap (or a watch in heart rate broadcast mode), talks to you during the session, and keeps every sample in an encrypted database on the phone.

Version 1 is Android only.

## What's in it

- **Devices**: any Bluetooth LE sensor using the Heart Rate Service (0x180D): Decathlon Kiprun/Kalenji, Polar, Garmin, Wahoo, Coospo, Magene straps, and Garmin, Polar, Coros, Suunto and Amazfit watches in broadcast mode. Auto-reconnect to the remembered device.
- **Onboarding**: welcome and disclaimer, PAR-Q+ style readiness questions, age/sex/weight, max and resting HR (entered, measured or estimated with Tanaka or a cautious formula), pairing with the 90-second device test, and alert preferences.
- **Device test**: device type, signal, skin contact, plausible reading, response to effort, RR availability, screen-locked delivery and voice, ending in *Ready for alerts*, *Works with limits* or *Problem found*, plus a "what this device can do" card.
- **Running mode**: GPS distance with jitter filtering and auto-pause, distance and target time, suggested target zone, splits, finish projection, drift, final push, sustainability and safety prompts.
- **Heart-rate-only mode**: Gym, Indoor cycling, Treadmill, HIIT, Yoga, Free monitoring; time or time-in-zone goals, interval timer, "ready for next set" recovery alerts. Never asks for location.
- **Alert planner**: segments with zones, ceilings, floors and pace, repeat blocks, custom rules (distance, time, HR, zone, pace, segment triggers) with voice, vibration, notification or log delivery, cooldowns and repeat limits, a preview timeline, saved plans and per-distance defaults.
- **Calories, carbs and water**: Keytel heart rate calories with an ACSM GPS cross-check, carb reminders sized from what you carry (Jeukendrup 2014 / ACSM 2016), water reminders (ACSM 2007, drink to thirst), "Taken" and "Drank" buttons, sweat test.
- **Coach logic**: 5-second smoothing, 10 s + 2 BPM zone hysteresis, 45 s cooldowns, priority merging, escalation to timed reminders, flat-line detection, sensor loss and low battery.
- **Post-run stats**: summary with goal and takeaway, HR chart on zone bands with alert markers and pace, time in zones, splits with fastest/hardest, route map coloured by zone, drift, efficiency, 1-minute recovery, RMSSD, effort blocks, plan adherence, best efforts, history calendar, weekly distance and load, efficiency trend, personal bests, GPX/TCX export with a privacy zone.
- **Privacy**: SQLCipher database with its key in the Android Keystore, no account, no analytics, excluded from backups, one-tap delete everything.

## Build

Pushes to `main` run analysis and tests, build a signed, obfuscated release APK, and publish it as a GitHub Release. Signing needs two repository secrets: `KEYSTORE_BASE64` (the upload keystore, base64) and `KEYSTORE_PASSWORD`. Without them the workflow still builds a debug-signed APK as an artifact but publishes nothing.

Local: `flutter pub get && flutter test && flutter build apk --release`.

See [TESTING.md](TESTING.md) for what to check on a phone with each build.
