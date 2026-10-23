# Android

The Android app does what the iPhone app does: it notices by itself that you are driving, and before every
published radar ahead it says a sentence and posts a notification. Nothing to open, no start button, nothing to
leave on screen. The alert rules are the same code checked against the same route vectors as iOS
([SPEC.md](SPEC.md)); this page covers what is Android-specific.

The code lives in `android/`: `:core` is the platform-neutral engine (a file-by-file port of
`Sources/RadaresCore`), `:app` is the phone app described here.

## The legal line

The app warns from published positions only. Spain's Reglamento General de Circulación, art. 18.3, bans radar
detectors and jammers and leaves out "los mecanismos de aviso que informan de la posición de los sistemas de
vigilancia del tráfico". Nothing in the app senses, receives or interferes with a radar signal. Every radar keeps the
`source` and `attribution` the feed gives it: the Fuentes tab lists each one verbatim with its count and link, and
the map shows a radar's source when you tap it.

## How a drive starts and ends

Parked, the app uses no GPS. Google Play services holds the wake-ups while the app is not running:

| Wake-up | What it is | What the app does |
|---|---|---|
| Activity transition `IN_VEHICLE` enter | Android thinks you got into a vehicle | starts the drive service and the drive at once |
| Parked fence exit | a 400 m circle around where the last drive ended | starts the drive service, which probes for 60 s |
| `ON_FOOT` enter | you are walking | ends a drive that is on |
| `STILL` enter | you stopped | marks the fixes as stationary, which pauses the drive |

The drive service (`DriveService`) is a foreground service of type `location` that reads one position per second
from the fused location provider. During the 60 s probe, three fixes at 6 m/s or more start the drive; if the probe
ends without a drive, the fence is set again where the phone is and the service stops. An `IN_VEHICLE` transition in
the last 3 minutes starts the drive without waiting for the probe.

While driving, a stationary fix or 120 s under 1 m/s pauses the drive; a resume at 3 m/s or more within 10 minutes
continues it with the same pass ledger. A pause over 10 minutes, walking, or the core detector's end ends the drive:
the engine closes any open stretch, the ledger is written, a `driveEnded` row goes to the log, and the fence is set
400 m around the last fix. After a reboot or an app update `BootReceiver` registers the transitions and the fence
again.

Why "Allow all the time" is required: from Android 14, a foreground service of type `location` started while the
app is in the background is refused unless the app holds `ACCESS_BACKGROUND_LOCATION`. Every drive starts in the
background, so without it no drive starts with the phone in a pocket. The fence needs the same permission.

`ACTIVITY_RECOGNITION` is optional: without it only the fence wakes the app, and the first warning comes later in
the drive. Estado shows it amber.

## Voice and notifications

Each warning goes to two places at once, with the iOS rules ([AlertDispatcher.swift](../App/Sources/Surfaces/AlertDispatcher.swift)):

- **The voice.** `TextToSpeech` in Spanish (English when the phone is in English), as navigation guidance
  (`USAGE_ASSISTANCE_NAVIGATION_GUIDANCE`), with transient audio focus that ducks the music and is given back when
  the sentence ends. A missing Spanish voice turns the Voz row red.
- **The notification**, on the `radares` channel. Every warning and stretch entry posts one, tagged
  `<radarId>#<passSeq>` so a later pass of the same radar is a new banner. The previous radar's notification is
  removed when the next one posts, and a radar's own when it is passed. A radar for the opposite flow posts silently
  with ", sentido contrario" in the title and is not spoken.

The three channels:

| Channel | Importance | Why it exists |
|---|---|---|
| `radares` ("Avisos de radar") | high | the warning; high importance is what makes it a heads-up banner on the phone and on Android Auto |
| `conduccion` ("Conducción") | low, silent | Android requires a visible notification while a foreground service runs. It says "Radares Anunciados vigila los radares publicados", has no actions and no stop button. It is not a card to look at. |
| `estado` ("Estado") | default | at most one notice a day when an Estado row is red and the app is not open |

Every radar notification is extended with `CarAppExtender` and posted through `CarNotificationManager`, which is what
Android Auto needs to draw it on the car screen. With no car connected the same call lands on the phone.

Known gap: Android Auto gives the app no delivery receipt for a `CarAppExtender` notification. The log records
what was posted and whether a car host was connected, not whether the car showed the banner. The voice is the one
surface that reaches the driver in every case.

## Estado

Twelve rows, each ok, amber or red, with a short fix text on the red ones:

| Row | Red or amber when |
|---|---|
| Ubicación precisa | red: no location permission, or approximate only |
| Ubicación siempre | red: "Allow all the time" not chosen |
| Reconocimiento de actividad | amber: physical activity permission refused |
| Notificaciones | red: notifications off; amber: the `radares` channel lowered below high |
| Valla de aparcamiento | red: the fence failed to register; amber: no drive has ended yet |
| Transiciones | red: activity transitions failed to register; amber: not registered yet |
| Datos | the shared feed rule: red with no data, older than 7 days, under 2,000 radars or 3 failed downloads in a row; amber older than 2 days |
| Actualización en segundo plano | red: battery restricted for the app or the job not scheduled; amber: no run in 3 days |
| Voz | red: no Spanish voice; amber: the engine is still starting |
| Android Auto | never red; amber when a car was connected but the warning cannot pop up |
| Archivos | red: the app's files cannot be written |
| Último viaje | the shared rule: amber after a gap over 10 s between positions or a late warning |

Below the rows: Actualizar datos (download now), Autocomprobación (a synthetic fixed radar 600 m ahead pushed
through the real engine, voice and notification; you hear "Radar fijo a 600 metros, sentido Zaragoza. Límite 90."),
Exportar registro (the event log through the share sheet) and Borrar registro.

## The feed

The feed is `https://geiserx.github.io/radares-anunciados-ha/feed.geojson`, fetched with `If-None-Match` and a 15 s
timeout. A 304 keeps the file; a 200 is checked by the core validator (a `FeatureCollection`, at least 2,000
features, at least one fixed radar, `id`, `kind` and `geometry` on every feature) and then replaces
`feed.geojson` atomically, keeping the previous one as `feed.geojson.bak`. A body that fails keeps the old file and
counts a failure. `feed.meta.json` holds the ETag, the fetch time and the failure count; the feed's age comes from
there, never from file dates.

Refresh: a WorkManager job every 6 hours on any network, at app open when the feed is over 6 hours old, at drive
start when it is over 24 hours old, and from Estado. Stale data never disables warnings.

The bundled snapshot is not a second copy in git: the build's `copyFeedSnapshot` task copies the iOS app's
`App/Sources/Resources/feed-snapshot.geojson` and `.date` into the APK's assets. On first launch it is copied to
`feed.geojson` with its generation time as the fetch time, so the first drive after install works offline.

## The map

The Mapa tab shows OpenStreetMap raster tiles through osmdroid, inverted to a dark map, with the published radars
within 5 km of the map centre as markers, and the card of the current drive at the bottom ("Sin radares cerca" when
nothing is near). The card is for a glance when the app happens to be open; no warning depends on it.

The OSM tile usage policy is followed: every tile request carries the user agent
`RadaresAnunciados/<version> (https://github.com/GeiserX/radares-anunciados)`, the map shows
"© OpenStreetMap contributors, ODbL", tiles are cached only as osmdroid caches tiles already viewed, and nothing is
prefetched or downloaded for offline use.

## Privacy and dependencies

No account, no analytics, no server of the app's own, no Firebase, no Google Maps SDK. The one Google dependency is
Google Play services for the fused location provider, the geofence and activity recognition; a phone without
Google Play services cannot run the app. The only network requests are the feed download and the map tiles. Backups
and device transfer exclude every file. The event log and the pass ledger stay on the phone; the log can be
exported and deleted from Estado.

Permissions: `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`, `ACTIVITY_RECOGNITION`,
`POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `RECEIVE_BOOT_COMPLETED`, `INTERNET`. The
manifest removes the `WAKE_LOCK` that WorkManager would merge in (from Android 10 it runs on JobScheduler and needs
none), and asks for no full-screen intent and no battery-optimisation exemption.

## What differs from iOS

- iOS wakes on Core Location's monitor and significant-change; Android wakes on the geofence and activity transitions.
- iOS has no visible service while driving; Android shows the silent `conduccion` notification because it requires one.
- iOS shows the banner on CarPlay through a notification category; Android Auto needs `CarAppExtender` and a Car App
  Library app installed from Google Play.
- The Estado rows follow each platform: Sesión Siempre, Cambio significativo and CarPlay are iOS rows; Transiciones,
  Actualización en segundo plano (battery restriction) and Android Auto are Android rows. Datos and Último viaje use
  the shared rules in `:core`.

## File layout

```
android/
  settings.gradle.kts, build.gradle.kts, gradle/libs.versions.toml
  core/                      the engine, phrasing, feed and log rules (pure Kotlin)
  app/
    build.gradle.kts         SDK levels, signing from RADARES_* variables, copyFeedSnapshot
    src/main/AndroidManifest.xml
    src/debug/               DebugWakeReceiver (debug builds only)
    src/main/kotlin/io/github/geiserx/radares/
      RadaresApp.kt, AppGraph.kt
      drive/                 WakeUps, the three receivers, DriveService, DriveController, LocationSource
      surfaces/              AlertDispatcher, Speaker, Notifier
      feed/                  FeedClient, FeedStore, FeedRepository, FeedRefreshWorker
      health/                AppLog, HealthInputs, HealthReport, HealthCollector, SelfTest
      ui/                    MainActivity, Theme, MapScreen, EstadoScreen, FuentesScreen, Onboarding
    src/test/                JVM and Robolectric tests (SDK 34)
```

## Building and testing

Requirements: JDK 17 and the Android SDK (platform 37, build tools 37). From `android/`:

```sh
./gradlew :core:test :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
```

The app tests run every route vector through the app's own drive path (`DriveController` → engine → dispatcher,
with a fake voice) and check the spoken sentences against each vector's `spoken` lines; they also cover the notifier
(car extender, channel, one per pass), the drive rules (probe timeout, motion start, walking, pause end, fence
re-arm), the feed store and client (against a local HTTP server), the twelve Estado rows, onboarding, the
release manifest, and the user-facing text. Robolectric runs at SDK 34 ([`robolectric.properties`](../android/app/src/test/resources/robolectric.properties))
because SDK 36 needs JDK 21. The Android workflow runs all of it on every pull request.

`./gradlew :app:assembleRelease` without the `RADARES_*` variables gives an unsigned, minified APK; with all four
(`RADARES_KEYSTORE_PATH`, `RADARES_KEYSTORE_PASSWORD`, `RADARES_KEY_ALIAS`, `RADARES_KEY_PASSWORD`) it is signed.

## Proving it on an emulator

An emulator cannot fake an activity transition: the real receivers are not exported, and a hand-made intent
carries no `ActivityTransitionResult`. Debug builds add `DebugWakeReceiver` (in `src/debug`, absent from release,
which a test checks), which starts the drive service through the same path:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
for p in ACCESS_FINE_LOCATION ACCESS_BACKGROUND_LOCATION ACTIVITY_RECOGNITION POST_NOTIFICATIONS; do
  adb shell pm grant io.github.geiserx.radares android.permission.$p
done
adb shell am broadcast -a io.github.geiserx.radares.DEBUG_WAKE --es reason in_vehicle \
  -n io.github.geiserx.radares/.drive.DebugWakeReceiver
```

Then replay a route vector at 1 Hz with `adb emu geo fix <lon> <lat>` per fix (`python3 app/scripts/replay-vector.py <vector.json> | sh`, see [replay-vector.py](../android/app/scripts/replay-vector.py),
prints and runs them), and read the warning with `adb shell dumpsys notification --noredact | grep 'Radar fijo'` and
the sentence in `adb logcat -s Radares`. The emulator's Google Play image has only a stub of Android Auto, so the car
banner needs a real phone and the Desktop Head Unit.

## Verifying a download
