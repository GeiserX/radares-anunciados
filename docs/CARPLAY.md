# CarPlay

Radares Anunciados v1 is not a CarPlay app. The design is in [DESIGN.md](DESIGN.md), sections 4.2 and 4.5. The app reaches the car today through one path that needs no CarPlay entitlement:

- **Voice** through the car's audio (`AVAudioSession` mode `.voicePrompt`), which works on any iOS version and through any Focus.

Every warning is also a **Time Sensitive notification** on the phone. iOS draws it on the Lock Screen; once the CarPlay driving-task entitlement below is granted, iOS draws the same notification on the car screen, and the app changes nothing in how it warns. There is no card to start and nothing to leave on screen: the app wakes itself when the car moves, like the Home Assistant app, and warns.

## Español

No hay nada que abrir ni que dejar en pantalla: la app se despierta sola al empezar a conducir y avisa por voz y con una notificación urgente en el iPhone. Cuando Apple conceda el permiso de CarPlay, esa misma notificación aparecerá en la pantalla del coche.

Con el permiso de ubicación "Mientras se usa" y sin "Siempre", abrir la app es la única forma de empezar el viaje.

## English

There is nothing to open and nothing to leave on screen: the app wakes on its own when you start driving and warns by voice and with a Time Sensitive notification on the iPhone. Once Apple grants the CarPlay entitlement, that same notification appears on the car screen.

With "While Using" location permission and no "Always", opening the app is the only way a drive can start.

## Later: a CarPlay driving-task app (optional, never the only path)

A CarPlay app would add a "next radar" screen and notifications on the car display. It needs the entitlement `com.apple.developer.carplay-driving-task`, which the maintainer requests at https://developer.apple.com/contact/carplay together with the CarPlay Entitlement Addendum (https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements). The request was filed on 2026-10-07; the notification work (the three rules below) starts when Apple answers.

### Entitlement request text (paste into the form)

> **App name:** Radares Anunciados
>
> **Bundle ID:** io.github.geiserx.radares
>
> **Requested entitlement:** CarPlay Driving Task (com.apple.developer.carplay-driving-task)
>
> **Description:** Radares Anunciados warns drivers in Spain before the speed cameras whose positions are published in advance by public bodies (the Dirección General de Tráfico, regional and municipal police) and by OpenStreetMap. It never detects, receives or interferes with any radar signal: Spanish law (Reglamento General de Circulación, art. 18.3) expressly allows "mecanismos de aviso que informan de la posición de los sistemas de vigilancia del tráfico" and bans detectors, and the app is the allowed kind. Today the app warns by voice through the car audio and with a Time Sensitive notification on the iPhone. In CarPlay we would show one screen, a CPInformationTemplate with the next announced camera (type, road and kilometre point, speed limit when published), refreshed no more than once every 10 seconds, and the same notification on the car display when the driver approaches a camera, so the warning is visible without the iPhone. The app has no account, no server, no ads and no tracking; the only network request is a public GeoJSON file. It is free and open source (GPL-3.0-or-later): https://github.com/GeiserX/radares-anunciados
>
> **Driving task:** The app supports the driving task by telling the driver, ahead of time and hands-free, that a published speed-control point is coming and what the limit is, so the driver can adjust speed safely. All interaction is glanceable; there is no browsing, text entry or media.

### Rules that apply once the entitlement exists

From the CarPlay App Programming Guide (https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf) and Apple's answers on the developer forums:

- **Authorization option.** Add `.carPlay` to the notification request: `requestAuthorization(options: [.alert, .sound, .carPlay])`. Today the request is `[.alert, .sound]`; `.carPlay` is added only after the entitlement is granted.
- **Category.** Register the radar notification's category with `UNNotificationCategoryOptions.allowInCarPlay`. "Apps must be approved for CarPlay overall and then you must enable CarPlay for the notification types you want displayed."
- **iOS 18.4 floor.** "Starting in iOS 18.4, notifications are also supported in CarPlay driving task apps." An Apple Frameworks Engineer confirms the floor (https://developer.apple.com/forums/thread/795990); a device on iOS 18.0 to 18.3 never shows them, while the app's deployment target stays iOS 18.0.
- **App icon on the CarPlay Home Screen.** Per Apple on the same thread, "Notifications on CarPlay requires the app icon present on the CarPlay Home Screen".
- **10 second refresh rule.** Driving-task guideline 4: "Do not periodically refresh data items in the CarPlay UI more than once every 10 seconds." The `CPInformationTemplate` is a static next-radar screen, never a live countdown; the voice carries the exact distance.
- **Scene.** A `CPTemplateApplicationScene` with its own scene delegate; the phone app keeps working with no CarPlay scene connected.

None of this changes the v1 surfaces: voice and the notification keep working with or without a CarPlay app.
