# CarPlay

Radares Anunciados is a CarPlay driving-task app since 0.1.2. Apple granted the entitlement
`com.apple.developer.carplay-driving-task` on 2026-10-07, the day it was requested. The design is in
[DESIGN.md](DESIGN.md), sections 4.3 and 4.5.

The experience is the one of a notification app, on the car screen as on the phone: nothing to start and nothing
to keep on screen. The app wakes itself when the car moves, warns by voice through the car's audio, and posts a Time
Sensitive notification; on iOS 18.4 or later iOS draws that same notification on the CarPlay screen. The CarPlay
scene exists so the app's icon is on the CarPlay Home Screen, which is what iOS requires before it mirrors the
notification; the driver never has to open it.

## Español

No hay nada que abrir ni que dejar en pantalla: la app se despierta sola al empezar a conducir y avisa por voz y
con una notificación urgente. En un coche con CarPlay (iOS 18.4 o posterior) esa misma notificación aparece en la
pantalla del coche, siempre que el icono de la app esté en la pantalla de inicio de CarPlay (lo está por defecto
cuando CarPlay conoce la app; si lo quitaste, vuelve a añadirlo en Ajustes › General › CarPlay › tu coche).

Si abres la app en CarPlay ves una sola pantalla: el próximo radar anunciado (tipo, carretera o nombre, distancia
redondeada como la dice la voz, límite si está publicado), «Sin radares cerca» cuando conduces sin nada por delante,
«Esperando a que arranque el viaje» cuando no hay viaje, y una línea «Estado» solo si algo está en rojo. Un botón
«Probar aviso» lanza el mismo aviso de prueba que el de la pestaña Estado, para ver la notificación llegar a la
pantalla del coche. Nada más: ningún ajuste se cambia desde el coche.

Con el permiso de ubicación "Mientras se usa" y sin "Siempre", abrir la app es la única forma de empezar el viaje.

La fila «CarPlay» de la pestaña Estado dice si el aviso puede salir en la pantalla del coche: verde cuando iOS lo
permite, ámbar si «Mostrar en CarPlay» está apagado en Ajustes › Notificaciones › Radares Anunciados, o si el
permiso de notificaciones no incluye CarPlay.

## English

There is nothing to open and nothing to leave on screen: the app wakes on its own when you start driving and warns
by voice and with a Time Sensitive notification. In a CarPlay car on iOS 18.4 or later that notification also
appears on the car screen, as long as the app's icon is on the CarPlay Home Screen (it is by default once CarPlay
knows the app; if you removed it, add it back in Settings › General › CarPlay › your car).

Opening the app in CarPlay shows one screen: the next announced radar (kind, road or name, distance rounded as the
voice says it, limit when published), "No radars nearby" while driving with nothing ahead, "Waiting for the drive to
start" when there is no drive, and a "Status" line only when something is red. A "Test warning" button runs the
same self-test as the Estado tab, so you can watch the notification reach the car screen. Nothing else: no setting
changes from the car.

With "While Using" location permission and no "Always", opening the app is the only way a drive can start.

The "CarPlay" row of the Estado tab says whether the warning can reach the car screen: green when iOS allows it,
amber when "Show in CarPlay" is off in Settings › Notifications › Radares Anunciados, or when the notification
permission does not include CarPlay.

## What the scene shows

`App/Sources/Surfaces/CarPlayScene.swift`: a `CPTemplateApplicationScene` declared in the Info.plist manifest
(role `CPTemplateApplicationSceneSessionRoleApplication`, delegate `CarPlaySceneDelegate`), with one
`CPInformationTemplate` titled "Radares Anunciados". `CarPlayContent.make(snapshot:report:locale:)` builds its rows
from the engine's `DriveSnapshot` and the Estado report, and is unit-tested:

| State | Rows |
|---|---|
| No drive (`snapshot == nil`) | "Esperando a que arranque el viaje" |
| Driving, nothing ahead | "Sin radares cerca" |
| Driving, a radar ahead | kind (", sentido contrario" for the other carriageway) with the road and km or the name; "Distancia" rounded to the voice's step (`Phrasing.roundedDistance`, 812 m shows "800 m"); "Límite" when the feed publishes one |
| Inside a stretch | "Quedan · aprox. 3 kilómetros" instead of the distance |
| Any state with a red Estado row | "Estado" with the first failing row's title |

The items refresh at most once every 10 seconds (`CarPlayRefreshThrottle`, driving-task guideline 4: "Do not
periodically refresh data items in the CarPlay UI more than once every 10 seconds"), and only when something
changed. It is never a live countdown; the voice carries the exact moment. The Estado report is re-collected once a
minute. The phone's own scene is SwiftUI's and keeps working with no CarPlay connected.

## Every condition for the banner on the car screen

Sources: the CarPlay App Programming Guide, "Notifications" (https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf),
the `allowInCarPlay` reference (https://developer.apple.com/documentation/usernotifications/unnotificationcategoryoptions/allowincarplay),
the `requestAuthorization` reference (https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:))
and Apple's answers on https://developer.apple.com/forums/thread/795990.

| # | Condition | Apple's words | Where the app meets it |
|---|---|---|---|
| 1 | The CarPlay entitlement, in the signature and in the provisioning profile | "Apps must be approved for CarPlay overall" | `com.apple.developer.carplay-driving-task` in `App/project.yml`; the `Radares App Store` profile carries it. `scripts/check-entitlements.sh` fails the release (`release.yml`, after the archive) when either the signature or the embedded profile lacks it or the Time Sensitive key |
| 2 | A driving-task app on iOS 18.4 or later | "Notifications are supported in CarPlay communication, EV Charging, parking, and public safety apps. Starting in iOS 18.4, notifications are also supported in CarPlay driving task apps." | Deployment target 18.0; Estado's CarPlay row says when the phone is older than 18.4 |
| 3 | The `.carPlay` authorization option | "In order to show notifications in CarPlay, include the carPlay option when requesting authorization for notifications." | `Notifier.authorizationOptions = [.alert, .sound, .carPlay]` in every request |
| 4 | The option recorded for a permission granted before it was asked | "Subsequent calls to this method don't prompt the person again." | 0.1.0 and 0.1.1 asked without `.carPlay`, so their grant reads `carPlaySetting == .notSupported`. `Notifier.addCarPlayToGrantedAuthorization()` asks again with the full options at every launch and when the CarPlay scene connects, only when the person already allowed notifications and iOS has no CarPlay setting. Apple says no prompt appears; that iOS then records `.carPlay` is the expectation, and VERIFY C10 confirms it. If it does not, deleting and reinstalling the app gives a fresh grant with the option |
| 5 | A category with `allowInCarPlay` on every notification meant for the car | "If a category doesn't explicitly contain this option, notifications of that type aren't displayed in a CarPlay environment." | The `radar` category, registered at launch; every radar notification carries it. The daily health notice has no category and stays on the phone |
| 6 | The app's icon on the CarPlay Home Screen | "Notifications on CarPlay requires the app icon present on the CarPlay Home Screen." | The CarPlay scene in the Info.plist manifest puts it there; a unit test reads the built Info.plist and resolves the delegate class. The app never has to be opened on the car screen |
| 7 | "Show in CarPlay" on in Settings | "Users can use Settings to show or hide your app's notifications in CarPlay." | Settings › Notifications › Radares Anunciados › Show in CarPlay. Estado's CarPlay row reads `carPlaySetting` and says when it is off |
| 8 | A banner while the app is in the foreground | `willPresent` decides how a foreground notification is presented | `Notifier.foregroundPresentation = [.banner, .list, .sound]`, so an open app (on the phone or on the car screen) still gets the banner |
| 9 | An interruption level that reaches the screen | Time Sensitive "presents the notification immediately, lights up the screen" | `interruptionLevel = .timeSensitive` with the Time Sensitive entitlement; a Focus may still hold it, the voice always speaks |

What only a car can prove is in [VERIFY.md](VERIFY.md), rows C10 to C14: whether a pre-0.1.2 grant gains the
CarPlay setting without a prompt, whether "Show in CarPlay" defaults on, and whether iOS draws the banner while the
app's own CarPlay screen is in front.

### What Estado shows

Estado has a CarPlay row, `HealthTitles.carPlay`, never red because the voice and the phone still warn without it:

| State | Row |
|---|---|
| `carPlaySetting == .enabled` | green, "Permitido: el aviso sale también en la pantalla del coche" |
| `.disabled` | amber, "Desactivado en Ajustes › Notificaciones › Radares Anunciados › Mostrar en CarPlay", with "Abrir Ajustes" |
| `.notSupported`, the phone has been on CarPlay | amber, "El permiso de notificaciones no incluye CarPlay: solo avisan la voz y el iPhone" |
| `.notSupported`, never on CarPlay | green, "El permiso de notificaciones no incluye CarPlay (aún no conectado a CarPlay)", with "Abrir Ajustes" |
| Notifications not allowed | amber once the phone has been on CarPlay (the Notificaciones row is the red one) |
| iOS older than 18.4 | amber once the phone has been on CarPlay, "necesita iOS 18.4 o posterior" |

"Has been on CarPlay" is `Notifier.carPlaySeenKey` in UserDefaults, set when the CarPlay scene connects or when
Estado is collected with the car as the audio route (`AVAudioSession` port `.carAudio`).

### How the Home Assistant companion app gets the banner

The HA iOS app (https://github.com/home-assistant/iOS) shows its notifications on CarPlay with less than the list
above. Its entitlements (`Configuration/Entitlements/App-ios.entitlements` plus
`activate_special_entitlements.sh`, which adds `com.apple.developer.carplay-driving-task` and
`com.apple.developer.carplay-voice-based-conversation` to release builds) carry Time Sensitive and Communication
notifications. Its `requestAuthorization` options (`UNAuthorizationOptions.defaultOptions` in
`Sources/App/Utilities/Permissions.swift`) are `[.alert, .badge, .sound, .providesAppNotificationSettings,
.criticalAlert]`, without `.carPlay`, and its notification categories have no `allowInCarPlay` (the property is
commented out in `Sources/Shared/API/Models/NotificationCategory.swift`). So on a real phone a driving-task app's
notifications reach the car screen even without rules 3 and 5; we keep both because they are what Apple documents,
and a category without the option is the one case the reference says is never shown. The shared conditions are the
ones that matter in practice: the driving-task entitlement in the signed build, iOS 18.4, the icon on the CarPlay
Home Screen, and "Show in CarPlay" on.

## Android Auto

There is no Android app yet. What it would need for the same banner on Android Auto is in
[ANDROID-AUTO.md](ANDROID-AUTO.md).

## The iOS 18.4 floor

"Starting in iOS 18.4, notifications are also supported in CarPlay driving task apps." An Apple Frameworks Engineer
confirms the floor on the same thread. The deployment target stays iOS 18.0: on 18.0 to 18.3 the voice and the
phone's notification work as before and the car screen shows the information template only.

## Entitlement and signing

The App ID `io.github.geiserx.radares` has the CarPlay Driving Task capability enabled, and the App Store
provisioning profile `Radares App Store` was regenerated with it (together with Time Sensitive Notifications).
`App/project.yml` writes `com.apple.developer.carplay-driving-task: true` into the entitlements; `xcodebuild
archive` fails against a profile made before the capability was enabled, as it does for Time Sensitive. A simulator
build carries the same entitlements file (`codesign -d --entitlements :- RadaresAnunciados.app`).

## Verification

Device-only rows live in [VERIFY.md](VERIFY.md), "CarPlay": CarPlay Simulator over USB and a real head unit. The
iOS Simulator's own CarPlay window (`defaults write com.apple.iphonesimulator CarPlayExtendedDisplay -bool YES`,
then I/O › External Displays › CarPlay) shows the icon and the information template; whether the notification is
mirrored there is not evidence for a device.

## History

- 2026-10-07: entitlement requested at https://developer.apple.com/contact/carplay with the CarPlay Entitlement
  Addendum (https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements), and granted the
  same day.
- 0.1.2: the scene, the `.carPlay` option and the `allowInCarPlay` category.
- Next release: the `.carPlay` option added to a permission granted on 0.1.0 or 0.1.1, the Estado CarPlay row, the
  foreground banner as a named constant, and the release gate on the signed entitlements.
