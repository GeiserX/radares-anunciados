# Android Auto

How a radar warning from the Android app reaches the Android Auto screen, what has to be true for it to show, and
how to check it. The iOS counterpart is [CARPLAY.md](CARPLAY.md); the rest of the Android app is in
[ANDROID.md](ANDROID.md).

## In one paragraph

Every warning is spoken, and the voice goes through the car speakers in every case: Android Auto plays the phone's
navigation-guidance audio. On the car screen, the warning shows as a heads-up banner, and the app has one screen
in the car's launcher listing the nearest published radars with their sources. The banner and the screen need the
app to be installed from Google Play (the Internal testing track is enough). An APK installed by hand from the
GitHub release gives the voice warning in the car, but Android Auto does not show the app or its banner.

## What was built

- **The banner.** Every warning notification is built with `NotificationCompat.Builder` on the `radares` channel
  (`IMPORTANCE_HIGH`), extended with `CarAppExtender`, and posted with `CarNotificationManager`
  (`android/app/src/main/kotlin/io/github/geiserx/radares/surfaces/Notifier.kt`). There is one code path: with no
  car connected the same notification lands on the phone. One notification per radar pass, id
  `<radarId>#<passSeq>`, cancelled once the radar is passed. A radar on the other carriageway is silent with
  ", sentido contrario" in the title, as on iOS.
- **The car app.** `RadaresCarAppService` declares the Car App Library category `androidx.car.app.category.POI`
  and opens `NearbyScreen`, a `PlaceListMapTemplate` with up to six of the nearest alertable radars around the last
  position: the kind ("Radar fijo"), the distance, the limit when published, and the source. With nothing near it
  says "Sin radares cerca". A "Fuentes" button opens the attributions and "© OpenStreetMap contributors, ODbL".
  The screen refreshes only when its rows change and at most once every 10 seconds. It is not a card to keep on
  screen; the driver never has to open it.
- **Manifest.** The service with the POI intent filter, `com.google.android.gms.car.application` pointing at
  `res/xml/automotive_app_desc.xml` (`<uses name="template"/>`), `androidx.car.app.minCarApiLevel` 1, and the
  permission `androidx.car.app.MAP_TEMPLATES`, without which the host refuses the map template.
- **Host check.** Debug builds accept any host (so the Desktop Head Unit works); release builds accept only the
  Android Auto hosts listed in `res/values/hosts_allowlist.xml`, the list from Google's Car App Library samples.
- **Estado.** The "Android Auto" row reads whether notifications and the `radares` channel are on at high
  importance, and whether a car host has connected to the car app since the app started.

## Why a car app at all

Android Auto does not mirror a phone's notifications. A notification reaches the car screen only when:

1. **The app is an Android for Cars app.** It declares a `CarAppService` with a supported category, built on the
   Car App Library (`androidx.car.app`). A radar warner has no category of its own; `POI` (a list of places on a
   map) is the closest fit. Home Assistant's app uses `IOT`.
2. **The notification is extended with `CarAppExtender`.** "Notifications only show up in the car screen if it is
   extended with CarAppExtender, even if the extender does not override any properties"
   (https://developer.android.com/reference/androidx/car/app/notification/CarAppExtender).
3. **It is posted with `CarNotificationManager.notify(...)`**, not `NotificationManager` (same page).
4. **The channel has `IMPORTANCE_HIGH`** for a heads-up banner: "A heads-up-notification (HUN) will show if the
   importance is set to IMPORTANCE_HIGH". Below that it only lands in the car's notification list.
5. **One banner per radar.** "Updating the same notification will not trigger another HUN event", so every pass
   gets a new id.

The Home Assistant Android app does the same: `HaCarAppService` declared with a category, and a notification sent
with `car_ui: true` extended with `CarAppExtender` and posted through `CarNotificationManager`
(https://github.com/home-assistant/android, https://companion.home-assistant.io/docs/android-auto/android-auto#notifications).

## Rejected: dressing the warning as a message

Android Auto also shows `MessagingStyle` notifications from messaging apps
(https://developer.android.com/training/cars/communication/notification-messaging), and that route works for an
APK installed by hand. We do not use it. It needs reply and mark-as-read actions that a radar warning cannot
have, and it is reserved for messaging apps, so a Play listing built on it would break Google's rules for that
category. A radar warning is not a message.

## The install-source rule

"To test your app in real vehicles, you must install it from a trusted source such as Google Play"
(https://developer.android.com/training/cars/testing). Android Auto's developer setting "Unknown sources" lifts
that rule for media, messaging and parked apps only: it "doesn't apply to apps built using the Android for Cars App
Library" (same page). So:

| Install | Voice in the car | Banner on the car screen | Radar screen in the car launcher |
|---|---|---|---|
| Google Play, any track (Internal testing is enough) | yes | yes | yes |
| APK from the GitHub release, real car | yes | no | no |
| Debug APK, Desktop Head Unit on a computer | yes | yes | yes |

The Internal testing track needs no review and takes up to 100 testers
(https://google.play/business/internal-testing/). Every `android-v*` GitHub release attaches the `.aab`
built by the same run as the APK, so it can be uploaded to Play without a rebuild.

## What does not work sideloaded

These steps turn on Android Auto's developer mode and its "Unknown sources" setting. They make the app show in the
Desktop Head Unit. In a real car they do not make a sideloaded Car App Library app appear, so they are not
install steps; the README does not list them on purpose.

1. On the phone, open Android Auto's settings (Settings > Connected devices > Connection preferences >
   Android Auto, or the Android Auto app).
2. Scroll to the bottom and tap **Version** ten times. Confirm the developer-mode prompt.
3. Open the three-dot menu > **Developer settings** and turn on **Unknown sources**.
4. Back in Android Auto's settings, **Customize launcher** lists the apps the car can show; Radares Anunciados
   appears there only for a Play install, or in the Desktop Head Unit.

## Checking the banner on a computer (Desktop Head Unit)

The Desktop Head Unit (DHU) is Google's Android Auto screen in a window on a computer
(https://developer.android.com/training/cars/testing/dhu). The emulator's Google Play image ships only an Android
Auto stub, so the DHU needs a real phone.

1. Phone: Developer options on, **Wireless debugging** on, paired with the computer once
   (`adb pair <ip>:<port>`, then `adb connect <ip>:<port>`).
2. Phone: Android Auto developer mode and **Unknown sources** on (steps above), then Android Auto's three-dot menu
   > **Start head unit server**. A notification says the server is running.
3. Computer: install the debug build, `adb install -r android/app/build/outputs/apk/debug/app-debug.apk`, and go
   through the app's permission screens on the phone.
4. Computer: `adb forward tcp:5277 tcp:5277`, then `desktop-head-unit` from
   `$ANDROID_HOME/extras/google/auto/` (add `-h` for a larger window).
5. In the DHU: the Radares Anunciados icon is in the launcher; opening it shows the radar list, or
   "Sin radares cerca".
6. Phone: Estado > **Autocomprobación**. It pushes a synthetic radar 600 m ahead through the real engine and the
   real notification path. Expected: the heads-up banner on the DHU screen and the voice through the computer's
   speakers.

## What to check in a car

Once the app is installed from Play:

- The banner on the car screen with the phone locked in a pocket, the app never opened that day.
- The banner while another app (a navigation app, music) is in front on the car screen.
- The radar screen in the car's launcher: rows, sources, "Fuentes".
- With the `radares` channel lowered below high importance on the phone: no banner, the warning only in the car's
  notification list, and the Estado row "Android Auto" amber or red.
- With Do Not Disturb while driving on: the voice still speaks; note whether the banner was held.

## Known gap

Android Auto gives no delivery receipt for a `CarAppExtender` notification. The log records what was posted and
whether a car host was connected, not whether the car drew the banner.

## The legal line

The app warns from published positions only (RGC art. 18.3,
https://www.boe.es/buscar/act.php?id=BOE-A-2003-23514#a18). Nothing in it senses, receives or jams a radar signal.
The car screen shows each radar's source, and the map data carries the OpenStreetMap attribution (ODbL).
