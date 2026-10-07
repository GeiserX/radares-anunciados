# CarPlay

Radares Anunciados v1 is not a CarPlay app. The design is in [DESIGN.md](DESIGN.md), sections 4.2 and 4.5. The app reaches the car in two ways that need no CarPlay entitlement:

- **Voice** through the car's audio (`AVAudioSession` mode `.voicePrompt`), which works on any iOS version and through any Focus.
- **The Live Activity** on the CarPlay Dashboard, iOS 26 and later. CarPlay draws the activity's small family (`.supplementalActivityFamilies([.small])`): kind symbol, title, distance in large digits and the limit badge, with no buttons, because Live Activities in CarPlay are non-interactive. When the Dashboard is not on screen, CarPlay shows a Live Activity alert as a notification at the bottom of the display (WWDC25 session 216, https://developer.apple.com/videos/play/wwdc2025/216/).

The Live Activity has one hard limit. An app cannot start it from a background wake-up such as a location event. Apple's DTS: "It is not possible to programmatically initiate a Live Activity from a background execution context, such as a CLLocationManager wakeup, using local APIs." (https://developer.apple.com/forums/thread/818467). A Shortcut, a control or Siri running a `LiveActivityIntent` may start one. There is also no API that launches an app when the iPhone connects to CarPlay; DTS recommends a Shortcuts automation instead (https://developer.apple.com/forums/thread/820693). Hence the recipe below.

## Español

### La automatización de Atajos (una vez)

Con ella, la tarjeta aparece en la pantalla del coche cada vez que conectas CarPlay, sin tocar el iPhone.

1. Abre **Atajos** y ve a la pestaña **Automatización**.
2. Toca **+** (Nueva automatización).
3. Elige **CarPlay**, marca **Conecta** y desmarca **Se desconecta**.
4. Elige **Ejecutar inmediatamente**, no "Ejecutar tras confirmar", y desactiva **Notificar al ejecutarse** si no quieres un aviso cada vez.
5. Toca **Siguiente**, busca **Radares Anunciados** y elige la acción **Iniciar aviso de radares**.
6. Toca **OK**.

Opcional: una segunda automatización con **CarPlay → Se desconecta → Ejecutar inmediatamente → Parar aviso de radares** termina el viaje al bajar del coche. No hace falta, porque la app termina el viaje sola tras 10 minutos parada.

CarPlay está entre las automatizaciones personales que se ejecutan sin pedir confirmación (https://support.apple.com/es-es/guide/shortcuts/apd602971e63/ios).

### Las tres formas de empezar

1. **La automatización de CarPlay** de arriba: lo normal en un coche con CarPlay.
2. **El control "Conducir"**: añádelo al Centro de control, a la pantalla bloqueada o al botón de Acción (Ajustes → Botón de Acción → Controles → Conducir). Un toque inicia el aviso y la tarjeta.
3. **Abrir la app** antes de salir.

Sin ninguna de las tres, la app sigue avisando por voz y con la notificación cuando iOS la despierta al empezar a conducir, pero la tarjeta no aparece en el coche en ese viaje. Estado lo indica con "Pantalla del coche no iniciada en el último viaje".

Con el permiso de ubicación "Mientras se usa" y sin "Siempre", la ubicación no puede empezar desde la automatización. La tarjeta dice "Abre la app" y hay que abrirla.

## English

### The Shortcuts automation (once)

With it the card appears on the car screen every time CarPlay connects, without touching the iPhone.

1. Open **Shortcuts** and go to the **Automation** tab.
2. Tap **+** (New Automation).
3. Choose **CarPlay**, tick **Connects** and untick **Disconnects**.
4. Choose **Run Immediately**, not "Run After Confirmation", and turn off **Notify When Run** if you do not want a banner each time.
5. Tap **Next**, search for **Radares Anunciados** and pick the action **Start radar warnings** (Iniciar aviso de radares).
6. Tap **Done**.

Optional: a second automation, **CarPlay → Disconnects → Run Immediately → Stop radar warnings**, ends the drive when you leave the car. You don't need it, because the app ends the drive by itself after 10 minutes stopped.

CarPlay is one of the personal automations that run without asking (https://support.apple.com/guide/shortcuts/apd602971e63/ios).

### The three starters

1. **The CarPlay automation** above: the normal case in a car with CarPlay.
2. **The "Drive" control** (Conducir): add it to Control Center, the Lock Screen or the Action button (Settings → Action Button → Controls → Drive). One tap starts the warnings and the card.
3. **Opening the app** before setting off.

Without any of the three, the app still warns by voice and with the notification when iOS wakes it at the start of a drive, but the card does not appear in the car for that drive. Estado says so ("Pantalla del coche no iniciada en el último viaje").

With "While Using" location permission and no "Always", location cannot start from the automation. The card says "Abre la app", Spanish for "Open the app", and the app has to be opened.

## Later: a CarPlay driving-task app (optional, never the only path)

A CarPlay app would add a "next radar" screen and notifications on the car display. It needs the entitlement `com.apple.developer.carplay-driving-task`, which the maintainer requests at https://developer.apple.com/contact/carplay together with the CarPlay Entitlement Addendum (https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements).

### Entitlement request text (paste into the form)

> **App name:** Radares Anunciados
>
> **Bundle ID:** io.github.geiserx.radares
>
> **Requested entitlement:** CarPlay Driving Task (com.apple.developer.carplay-driving-task)
>
> **Description:** Radares Anunciados warns drivers in Spain before the speed cameras whose positions are published in advance by public bodies (the Dirección General de Tráfico, regional and municipal police) and by OpenStreetMap. It never detects, receives or interferes with any radar signal: Spanish law (Reglamento General de Circulación, art. 18.3) expressly allows "mecanismos de aviso que informan de la posición de los sistemas de vigilancia del tráfico" and bans detectors, and the app is the allowed kind. Today the app warns by voice through the car audio and shows a Live Activity on the CarPlay Dashboard. In CarPlay we would show one screen, a CPInformationTemplate with the next announced camera (type, road and kilometre point, speed limit when published), refreshed no more than once every 10 seconds, and a notification on the car display when the driver approaches a camera, so the warning is visible without the iPhone. The app has no account, no server, no ads and no tracking; the only network request is a public GeoJSON file. It is free and open source (GPL-3.0-or-later): https://github.com/GeiserX/radares-anunciados
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

None of this changes the v1 surfaces: voice and the Live Activity keep working with or without a CarPlay app.
