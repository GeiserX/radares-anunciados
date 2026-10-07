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

## The three notification rules

From the CarPlay App Programming Guide (https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf)
and Apple's answers on the developer forums (https://developer.apple.com/forums/thread/795990). All three are in
the app:

1. **Authorization option.** Every notification request asks `Notifier.authorizationOptions`,
   `[.alert, .sound, .carPlay]` (onboarding, and the provisional path of the self-test and the simulator scripts
   adds `.provisional`).
2. **Category.** `Notifier.registerCategories()` registers the `radar` category with
   `UNNotificationCategoryOptions.allowInCarPlay` at launch, and every radar notification carries that category
   identifier ("Apps must be approved for CarPlay overall and then you must enable CarPlay for the notification
   types you want displayed"). The daily health notice has no category and stays on the phone.
3. **App icon on the CarPlay Home Screen.** "Notifications on CarPlay requires the app icon present on the CarPlay
   Home Screen": the scene above is what puts it there.

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
