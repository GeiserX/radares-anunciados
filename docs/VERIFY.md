# Device verification

Owned by the location lane. The design ([docs/DESIGN.md](DESIGN.md), sections 3, 4 and 10) makes claims that only a
real iPhone can settle: when the parked fence wakes the app, whether a cold background launch can speak, what a Driving
Focus lets through, how many Live Activity updates the system delivers, and how the card looks on a car screen.
This file is the checklist. Each row has an expectation written before the drive and a result column filled in
after it, with the log rows that prove it (Estado exports `events.jsonl`). A row whose result cannot be read from
the log is not a pass.

How to fill a row: `pass`, `fail` or `pending`, the date, the iOS version, and the log rows or the Console.app
lines that back it. Keep failed rows: they are the reason a design decision changes.

## Rules this checklist enforces

- **The Always session is re-taken within the first second of every launch, from the launch path, never from a
  view.** DTS, [thread 799094](https://developer.apple.com/forums/thread/799094): an explicit session must be recreated "asap upon launch in the background, otherwise
  your app will be assumed to no longer have interest in location updates". The coordinator takes it in its own
  `init`, which the app delegate touches as the first statement of `didFinishLaunching`. Proof: in every background
  launch `sessionTaken` precedes `probe` in the log.
- **A `CLBackgroundActivitySession` (While-Using mode) is rejoined from every launch path and never invalidated
  there.** DTS, [thread 770063](https://developer.apple.com/forums/thread/770063), names the two failures: invalidating the session after the app was killed, and not
  rejoining it from a non-UI launch. It is invalidated only at drive end, by the code that ended the drive.
- **A force-quit app may never come back on iOS 26.** [Forum thread 826964](https://developer.apple.com/forums/thread/826964) reports that an app the user swiped away
  on iOS 26.4.2 was never relaunched by significant change or a region exit, where iOS 18 relaunched it. Onboarding
  says never to swipe the app away, Estado turns red on `willTerminate`, and the "Conducir" control restarts the
  chain. The row below records what the test device does.

## Real iPhone checklist

Everything below runs on a real iPhone with the TestFlight or a development build, Always authorization, Precise
Location on, Background App Refresh on, Low Power Mode off, and the Estado log exported after each session.

### Wake-ups and the first kilometres

Expectation for the fence (design 3.1): the exit is reported, at best, radius 400 m plus Apple's cushion of about
200 m plus 20 s of dwell into the drive, so about 0.9 km at 50 km/h, 1.1 km at 90 and 1.3 km at 120, before the
launch and up to 30 s of GPS warm-up. Apple's own figure for a region report is "within 3 to 5 minutes on average",
network dependent, which at 120 km/h is 6 to 10 km. The number to record is `firstWarnAfterWakeM` in the
`driveEnded` row; the written expectation is 1 to 3 km, not 600 m. Over a week of drives these rows decide whether
v1.1 adds radar rings (design 11, risk 7).

| # | Test | Expectation | Result |
|---|---|---|---|
| W1 | Park, lock the phone, leave it a day without opening the app, then drive | A `launch(reason: monitorEvent)` or `launch(reason: slc)` row, then `sessionTaken`, `wakeup`, `probe(result: driving)`, `driveStarted(reason: wakeup(...))` | pending |
| W2 | Which wake-up fires first, over ten cold starts | Count `wakeup(source:)` rows; both sources appear; neither is always first | pending |
| W3 | Fence exit distance at 50, 90 and 120 km/h | `firstFixAfterWakeS` and `firstWarnAfterWakeM` in `driveEnded`; expected 1 to 3 km before the first warning, launch and warm-up included | pending |
| W4 | Is 400 m the right radius | Only drives with a `wakeup(source: monitor)` row count, and the measure is the exit itself, not the first warning (W3's `firstWarnAfterWakeM` also depends on where the next radar is). Note the time you pulled out of the parking spot; the `wakeup` row's timestamp minus that time, at the speed driven, is the exit distance from the parked position. Under 1 km at 90 km/h: the radius stays. Past 3 km: a reason for radar rings, not for a larger radius (a larger radius only delays the exit) | pending |
| W5 | Wi-Fi off, cellular only, cold wake | Fence exit still reported (Apple: "significantly less accurate" without Wi-Fi); `wakeup(source: slc)` arrives at the latest within one SLC period | pending |
| W6 | Airplane mode (no network, GPS only), warm app | Fixes keep coming at 1 Hz while driving; no `feedFailed` affects alerts | pending |
| W7 | Stop in a motorway jam for 3 minutes | `drivePaused`, then `driveResumed(pausedSeconds:)` under 600 s, same drive, no second alert for a radar already fired | pending |
| W8 | Park for 12 minutes, drive again | `drivePaused`, `driveEnded`, then `probe` with `motion: true` and `driveStarted` on the first fixes (the motion gate shortens the probe) | pending |
| W9 | Park and walk away | `drivePaused`, then `driveEnded` within a minute of walking, no further GPS (Settings > Privacy > Location: the arrow goes grey) | pending |
| W10 | Relaunch after a system kill (leave the phone a day with other apps open, then drive) | The `launch` row of the drive has `state: background`; `sessionTaken` precedes `probe` | pending |
| W11 | Reboot, unlock, drive | Same rows as W10; nothing arrives before the first unlock | pending |
| W12 | Force-quit from the switcher, then drive (iOS 26 behaviour, thread 826964 above) | Record whether a `launch` row appears at all. Either outcome is written here; `willTerminate` was logged at the swipe | pending |
| W13 | Toggle "Avisos" off, drive 5 km, toggle on, drive | Off: no `wakeup`, no `probe`, Settings shows no location use. On: the next drive starts from a wake-up again | pending |

### Speech

| # | Test | Expectation | Result |
|---|---|---|---|
| S1 | **Background-launch speech.** App terminated, phone locked in a pocket, drive started by the CarPlay automation or by a cold wake, never foregrounded, past one fixed radar | A `speech(route:, setActiveError: nil, finished: true, launchContext: background)` row. If `setActiveError` is set from a cold background launch, switch on the once-per-drive activation fallback of design 4.1 and record which variant shipped | pending |
| S2 | CarPlay, music playing | The sentence over the car speakers, music ducked and restored; `route: carAudio` | pending |
| S3 | Bluetooth A2DP, podcast playing (an app that sets `.spokenAudio`) | The podcast pauses, the sentence plays, the podcast resumes; `route: bluetoothA2DP` | pending |
| S4 | Silent switch on, screen locked, phone speaker | The sentence still plays (`.playback` category) | pending |
| S5 | Two radars inside 8 s | One sentence, the second as a `.visual` row; the log shows the pacing | pending |

### Driving Focus

No Apple page says a Time Sensitive notification or a Live Activity alert passes a Driving Focus (design 4.3). The
two rows are the measurement. Set up a Driving Focus that turns on automatically when connected to the car's
Bluetooth, no allowed apps.

| # | Test | Expectation | Result |
|---|---|---|---|
| F1 | **Time Sensitive notification through a Driving Focus** (no Live Activity running: start the drive from a cold wake, not from the automation) | Record whether the banner appears on the Lock Screen at the warn distance, and whether it waits until the Focus ends. The log row `notificationPosted(error: nil)` only proves the post | pending |
| F2 | **Live Activity alert through a Driving Focus** (drive started by the automation, so the activity exists) | Record whether the `.full` alert lights the screen and expands the Dynamic Island, or whether only the content changes silently | pending |
| F3 | Same two tests with the Focus's "Time Sensitive notifications" allowed, where the Focus offers the switch | Record the difference, if any | pending |

Whatever F1 and F2 say, the voice is the surface that arrives: onboarding says so.

### Live Activity

| # | Test | Expectation | Result |
|---|---|---|---|
| L1 | **Cadence actually shown.** A 20 km drive past three radars, phone on the dashboard mount, Console.app streaming `liveactivitiesd` | Every milestone update (1,000 / 750 / 500 / 250 / 100 m, each phase change) is sent; `activityUpdated(dropped: false)` for each, or `dropped: true` rows plus `liveactivitiesd` budget lines. Record the ratio shown / sent here | pending |
| L2 | Stale date | With the app killed mid-drive, the Lock Screen marks the card stale within 2 minutes (15 minutes while paused) | pending |
| L3 | End | After `driveEnded`, the card lingers on the Lock Screen for 5 minutes and leaves CarPlay at once | pending |
| L4 | 8-hour cap | A drive over 8 h loses the card; speech and notifications continue (`speech` rows after the card is gone) | pending |

### CarPlay (iOS 26)

First with the iPhone on USB to a Mac running CarPlay Simulator (Additional Tools for Xcode), then on the real head
unit. Live Activities in CarPlay use the small activity family ([WWDC25 216](https://developer.apple.com/videos/play/wwdc2025/216/);
[CarPlay App Programming Guide](https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf),
"Live Activities in CarPlay"); without it CarPlay shows the compact Dynamic Island views.

| # | Size or mode | Expectation | Result |
|---|---|---|---|
| C1 | 240 x 78 pt | Kind symbol, "Radar fijo", distance in large digits, limit badge, nothing cut off | pending |
| C2 | 240 x 100 pt | Same, with the subtitle line visible | pending |
| C3 | 170 x 78 pt | Symbol, distance, limit; the title may drop | pending |
| C4 | Smart Display Zoom 1920 x 720 | Legible at arm's length | pending |
| C5 | Smart Display Zoom 900 x 1200 | Legible | pending |
| C6 | Smart Display Zoom 800 x 480 | Legible | pending |
| C7 | Night Mode | The red tint keeps the digits readable; no pure white block | pending |
| C8 | Dashboard hidden (a map app full screen) | The `.full` alert appears as the notification at the bottom of the display (WWDC25 216) | pending |
| C9 | Real head unit | Rows C1 to C8 repeated; note the car model and head unit software | pending |

### Everything else

| # | Test | Expectation | Result |
|---|---|---|---|
| E1 | "Probar aviso" in the foreground | The sentence, the card, the notification once the card is dismissed; one `alert` row with three sink outcomes | pending |
| E2 | The CarPlay Shortcuts automation (Atajos > Automatización > CarPlay > Conecta > Ejecutar inmediatamente > Iniciar aviso de radares) | `launch(reason: intent)`, `driveStarted(reason: intent)`, `activityStarted`, no confirmation prompt | pending |
| E3 | A week of Settings > Battery | The app's share stays under a navigation app's for the same driving minutes; Estado's 7-day drive minutes match the real drives | pending |
| E4 | Settings > Privacy > Analytics after a week | No jetsam report naming the app | pending |
| E5 | `maxGapSeconds` in every `driveEnded` row of the week | Under 10 s while moving; a larger gap is a row to explain (suspension, throttling) | pending |
| E6 | While-Using only (deny Always), app opened before the drive | The drive works with the blue pill; after `driveEnded` nothing wakes the app; Estado says "Sin permiso Siempre: abre la app antes de conducir". Measurement, not a feature: how long an outstanding `CLBackgroundActivitySession` would keep the wake-ups alive if it were never invalidated | pending |

The App Review recording (onboarding, Estado, "Probar aviso", a short drive past a radar with the Live Activity)
comes from one of these drives.

## Simulator

[`scripts/sim-drive.sh`](../scripts/sim-drive.sh) `<udid> <target> <km/h> <same|opposite> [--probe] [--state-machine-only] [--app <path>]`
drives a booted simulator along a route built from a fixture feature (or a `lat,lon` pair): 3 km before the gate
to 1 km past it (past the far gate for a stretch), grants `location-always`, sets `wantsAlways` in the app's
defaults as onboarding would, launches with `-StartDriveForTest 1` (or without it under `--probe`, so the
significant-change delivery wakes the idle app and the probe decides), runs `simctl location start` at 1 s
intervals, then prints the alert and state rows of `events.jsonl` and the same rows from the unified log. Mute the
Mac first: the app may speak. Run it on a build Mac, never on the laptop.

What the Simulator proves: the state machine, the fix flow and the engine's decisions on a straight route. What it
cannot prove: the radio, the scheduler, suspension, the region cushion and dwell, the audio route, the Live
Activity budget, CarPlay (CarPlay Simulator connects to a real iPhone over USB, not to the iOS Simulator).

Measured limits of the Simulator (Xcode 26.6, iOS 26.5, 2026-10-07):

- `simctl location` reports a valid speed and course with both accuracies at -1 (`speed 33.3±-1.0 course 90±-1`).
  The device rule of design 2.1 (nil on a negative accuracy) would discard every simulated fix, so
  `DriveSession.fix(from:)` ignores the accuracies under `targetEnvironment(simulator)` only.
- Significant change delivers the current position right after `startMonitoringSignificantLocationChanges()` and
  then about every 30 s while the position changes, so an idle app in the Simulator is woken within a minute of a
  route starting, long before a real phone would be.
- No update ever carries `isStationary == true`; the pause path is exercised with the 120 s slow rule (a route at
  0.5 m/s) instead.
- The system relaunches a terminated app for a significant-change delivery and for a `CLMonitor` exit, which is
  what the relaunch test below relies on.
- `CLMonitor` refuses a name with a dot (`Monitor Name contains non-alphanumeric character`, an assertion in
  `CLMonitor.mm`); the monitor is `RadaresWake`, not the design's `radares.wake`.
- A fresh Simulator speaks English: its language is `en-US`, and the sentence follows the phone's language. Set
  `AppleLanguages` to `es-ES` in the Simulator's global domain and reboot it before a run whose evidence is the
  Spanish sentence.
- `application.applicationState` is `.background` inside `didFinishLaunching` on every launch, a user's included;
  the background-wake rule is the location launch key (design 3.3), and a user launch is named by its scene.
- The Lock Screen cannot be reached from a headless run: locking needs the Simulator app and an Accessibility grant
  an ssh session cannot obtain. The milestone screenshots show the Live Activity in the Dynamic Island with the app
  in the background (Settings opened over it) and the in-app card; the Lock Screen itself is a device row (L1).
- Right after a route, the next launch gets a significant-change delivery for the last simulated position before
  the scene is up, so the probe, not `-StartDriveForTest`, starts that drive (`driveStarted(reason: wakeup(slc))`).
  Both paths are the design's; the Live Activity still starts because the app watches the drive state while open.

State-machine run (what `scripts/sim-drive.sh --probe --state-machine-only` plus a few `simctl location` commands
show; the rows come from the unified log, subsystem `io.github.geiserx.radares`, and from `events.jsonl` once the
core's `EventLog` is in):

1. Fresh install, `wantsAlways` set, launch: `Always session re-taken at launch`, `sessionTaken`, `launch`,
   `significant change started`, `monitor RadaresWake identifiers []`, then the first significant-change delivery:
   `launch reason slc`, `state idle -> probing`, `liveUpdates(.automotiveNavigation) started`, `motion gate: nil`
   (no Core Motion in the Simulator; the gate falls through, as designed).
2. Route at 33 m/s: three fixes at or above 6 m/s, `probe ended: driving`, `state probing -> driving`,
   `driveStarted(reason: wakeup(slc))`; one `update` row per second in the log.
3. Route at 0.5 m/s: after 120 s `state driving -> paused`, `drivePaused`, `parked fence armed` at the slow position.
4. Route at 25 m/s: `state paused -> driving`, `driveResumed(pausedSeconds:)`.
5. `simctl terminate`, then one `simctl location set` step: a new process, `Always session re-taken at launch`,
   `sessionTaken`, `launch`, `persisted drive resumed`, state `driving` without a probe.
6. Fresh install again, launch, let the probe time out (`probe ended: timeout`, `state probing -> idle`,
   `parked fence armed`), `simctl terminate`, then `simctl location set` steps of about 500 m: a new process with
   `sessionTaken` and `launch` before `state idle -> probing` and `probe`. That is the relaunch path of design 3.3.
