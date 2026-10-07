<h1 align="center">Radares Anunciados</h1>

<p align="center">
  <a href="https://github.com/GeiserX/radares-anunciados/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/GeiserX/radares-anunciados/ci.yml?style=flat-square&label=CI" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/GeiserX/radares-anunciados?style=flat-square" alt="License"></a>
</p>

Radares Anunciados is an iPhone app that warns a driver before the speed radars announced in Spain: the DGT's fixed and section radars, its mobile-radar stretches, the weekly lists of local police and OpenStreetMap. It speaks the warning through the car's audio and shows it on CarPlay and the Lock Screen, with the phone locked in a pocket and the app not opened that day.

## Features

- Spoken warning once per radar, at a distance that grows with speed (347 m at 50 km/h, 833 m at 120 km/h).
- Only radars ahead and in your direction of travel; a radar for the other carriageway is shown, not spoken.
- Mobile-radar and average-speed stretches with the remaining distance, and "Fin de tramo" at the end.
- A card on the CarPlay Dashboard and the Lock Screen (Live Activity), and a Time Sensitive notification when no card runs.
- Starts on its own when you drive, or from a CarPlay automation, the "Conducir" control or Siri.
- Works offline: the radar list is on the phone, refreshed every 6 hours, with a copy bundled for the first drive.
- An Estado screen that checks every link of the chain, and a "Probar aviso" button that runs a test warning through it.
- No account, no server, no ads, no tracking. Spanish and English.

## Quick start

The app is in beta on TestFlight: https://testflight.apple.com/join/TESTFLIGHT_CODE (link coming with the first build). It needs an iPhone with iOS 18 or later; the CarPlay card needs iOS 26.

To build it yourself on a Mac with Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
git clone https://github.com/GeiserX/radares-anunciados && cd radares-anunciados
swift test                                   # the RadaresCore package
xcodegen generate --spec App/project.yml && open App/RadaresAnunciados.xcodeproj
```

On first launch the app walks you through four screens: location (allow "Always" and Precise Location), notifications and Motion, the car screen, and Estado.

## How it works

1. When the car starts moving, Apple's significant-change and region services wake the app; a GPS probe confirms you are driving.
2. While you drive, one fix a second goes through the alert engine in `RadaresCore`, a Swift package with no platform code.
3. A radar fires when it is ahead, you are closing on it, it is within 25 seconds of driving (300 m to 1 km), and its direction matches yours.
4. The warning goes out by voice, on the Live Activity and as a notification, each one logged with its outcome.
5. When you stop for good the app ends the drive, re-arms a 400 m fence around where you parked, and goes back to sleep without GPS.
6. The radar list comes from the public feed of [radares-anunciados-ha](https://github.com/GeiserX/radares-anunciados-ha), checked and replaced atomically.

## Data, privacy and the law

The app warns from published positions only. Spain's Reglamento General de Circulación, [art. 18.3](https://www.boe.es/buscar/act.php?id=BOE-A-2003-23514#a18), bans radar detectors and jammers and leaves out of that ban "los mecanismos de aviso que informan de la posición de los sistemas de vigilancia del tráfico". The app never senses, receives or interferes with a radar signal. Respect the speed limits.

Sources and licences: DGT (CC BY 4.0), the local police weekly lists of León (ILEÓN, CC BY-NC 4.0) and Murcia (La Opinión de Murcia), and © OpenStreetMap contributors (ODbL 1.0); the database is under ODbL 1.0. Every radar keeps its source's attribution, and the app shows them on its sources screen. See [NOTICE](NOTICE).

Your location never leaves the phone; the only network request is the download of the public radar list. Details in [PRIVACY.md](PRIVACY.md).

## Documentation

- [Design](docs/DESIGN.md): the alert model, location strategy, surfaces, data and health checks
- [Spec](docs/SPEC.md): the platform-neutral rules and the route vectors, the contract for Android
- [Device verification](docs/VERIFY.md): what only a real iPhone and a real drive can prove
- [CarPlay](docs/CARPLAY.md): the automation recipe and the CarPlay rules
- [Contributing](CONTRIBUTING.md) and [Security](SECURITY.md)

## License

[GPL-3.0-or-later](LICENSE), with an additional permission for App Store distribution (see [NOTICE](NOTICE)).
