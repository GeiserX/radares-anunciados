# Android Auto

There is no Android app yet. This page says what one needs so the radar warning shows as a banner on the Android
Auto screen, the way the iOS app's notification shows on CarPlay ([CARPLAY.md](CARPLAY.md)). The engine, the
phrasing and the route vectors are platform-neutral ([SPEC.md](SPEC.md)); this is only the car-screen part.

## The rule

Android Auto does not mirror a phone app's notifications. A notification reaches the car screen only when:

1. **The app is an Android for Cars app.** It declares a `CarAppService` in its manifest with one supported
   category, built on the Car App Library (`androidx.car.app`). The categories the library defines are `NAVIGATION`,
   `POI`, `CHARGING`, `PARKING`, `IOT`, `WEATHER`, `MEDIA`, `MESSAGING`, `CALLING`, `SETTINGS` and
   `FEATURE_CLUSTER` (`androidx.car.app.category.*`, https://developer.android.com/reference/androidx/car/app/CarAppService).
   "Your app must belong to one of the supported categories and meet specific design requirements before it can be
   listed on Google Play for Android Auto" (https://developer.android.com/training/cars/apps). A radar warner has no
   category of its own; `POI` (a list of places on a map) is the closest fit, and Google's review decides. Home
   Assistant uses `IOT`.
2. **The notification is extended with `CarAppExtender`.** "Notifications only show up in the car screen if it is
   extended with CarAppExtender, even if the extender does not override any properties"
   (https://developer.android.com/reference/androidx/car/app/notification/CarAppExtender).
3. **It is posted with `CarNotificationManager.notify(...)`**, not `NotificationManager` or
   `NotificationManagerCompat` (same page).
4. **The channel has `IMPORTANCE_HIGH`** for a heads-up banner: "A heads-up-notification (HUN) will show if the
   importance is set to IMPORTANCE_HIGH". Below that it only lands in the car's notification list.
   `CarAppExtender.Builder.setImportance` overrides it for the car screen only.
5. **One banner per radar.** "Updating the same notification will not trigger another HUN event", and
   `setOnlyAlertOnce(true)` keeps an update quiet. Post a new id per pass (the iOS app's `<radarId>#<passSeq>`),
   remove the previous one, and update in place only for the distance.

Messaging-style notifications (`MessagingStyle` with reply and mark-as-read actions,
https://developer.android.com/training/cars/communication/notification-messaging) are the other route onto the car
screen, reserved for messaging apps. A radar warning is not a message; do not dress it as one.

## How Home Assistant does it

The HA Android app (https://github.com/home-assistant/android) declares `HaCarAppService` with
`androidx.car.app.category.IOT` (`app/src/full/AndroidManifest.xml`). A notification sent with `car_ui: true` is
extended with `CarAppExtender` and posted through `CarNotificationManager` (`MessagingManager.kt`). Its docs say
the channel must also pop up on the phone for the banner to show on top in Android Auto
(https://companion.home-assistant.io/docs/android-auto/android-auto#notifications). By default HA notifications do
not show in Android Auto; `car_ui: true` is what the HA blueprints need for the Android Auto banner.

## What the Android app's car part would be

- A `CarAppService` (category `POI`) whose one screen mirrors the CarPlay template: the next radar, rounded
  distance, limit, "Sin radares cerca", the first red Estado row. Refresh no faster than the host allows.
- A notification channel "Radares" with `IMPORTANCE_HIGH`, created at first launch; the Android counterpart of the
  iOS Time Sensitive level.
- Every radar notification built with `NotificationCompat.Builder`, extended with `CarAppExtender`, posted with
  `CarNotificationManager`; the opposite-carriageway row silent, as on iOS.
- An Estado row that reads `NotificationManagerCompat.areNotificationsEnabled()` and the channel's importance, the
  counterpart of the iOS CarPlay row.
- The same rule as iOS: warn from published positions only, every radar with its source and attribution.

Rows to check in a car, once it exists: the banner on the Android Auto screen with the phone locked, with the app
in front on the car screen, and with the channel lowered below high (no banner, list only).
