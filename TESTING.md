# Phone test checklist

Bluetooth, GPS, voice and background behaviour can only be checked on a real phone. Work through this with each build and note anything that fails.

## 1. Install and onboarding
- Install the APK from the GitHub Release (allow your browser to install unknown apps).
- Go through all six onboarding screens. Try skipping one.
- On "Pair and test", your strap should appear within a few seconds. Android asks for "Nearby devices" (Android 12+) and notifications.

## 2. Device test (strap on, pads wet)
- Every check runs: sit still 30 s, march on the spot, lock the phone for 30 s until it says "test done", play the sample alert.
- Expected with the Decathlon strap: **Ready for alerts**, RR available.
- If "Screen locked" fails, tap "Fix battery optimisation", allow it, and re-run the test from Settings.
- Optional: try a watch in broadcast mode and check it gets the "wrist reading" card.

## 3. Heart-rate-only session (indoors)
- Start "Heart rate only", Gym, no goal. Start should do a 5-second signal check.
- Lock the phone for at least 5 minutes with music playing. Voice alerts should duck the music, and the notification should show BPM.
- Take the strap off for 10 s: you should hear "Heart rate signal lost", then "signal back" when you put it on.
- Try the interval timer (e.g. 30 s work / 30 s rest / 3 rounds).
- Finish, stand still for the 1-minute recovery, check the summary tabs.

## 4. Run (outdoors)
- Run 3–5 km with the screen locked and music playing.
- You should hear a split every kilometre, projections every 2 km, and zone alerts if you go above the ceiling.
- Stop at a traffic light: time should auto-pause and resume.
- After finishing, check distance against a watch or another app, the map, splits and the HR chart.

## 5. Planner and fuel
- Build a plan with a repeat block and a custom "every 10 minutes" alert; check the preview, save it as default for the distance, and confirm it is offered next time.
- On a run over 45 minutes, carb and water reminders should fire, and the "Carbs taken" / "Drank" buttons should log.

## 6. Robustness
- Walk the phone away from the strap and back mid-session: it should reconnect by itself.
- Force-stop the app mid-session, reopen it: the session should be saved up to the crash.
- Settings > Delete everything wipes data and returns to onboarding.

Report: phone model and Android version, what failed, and roughly when in the session.
