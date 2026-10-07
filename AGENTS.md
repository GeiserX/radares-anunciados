# AGENTS.md: radares-anunciados

Radares Anunciados is an iPhone app that warns a driver before an announced speed radar in Spain. It reads the
open feed that [radares-anunciados-ha](https://github.com/GeiserX/radares-anunciados-ha) publishes
(`feed.geojson` and `status.json`), keeps the radars near the driver, and alerts with a spoken warning, a Time
Sensitive notification and a Live Activity (shown in CarPlay on iOS 26). There is no server and no account: the
app downloads the public feed and everything else happens on the phone. An Android app comes later.

## The legal line

The app warns from published positions only, which is what keeps it legal in Spain.
[RGC art. 18.3](https://www.boe.es/buscar/act.php?id=BOE-A-2003-23514#a18) bans radar detectors and jammers in a
vehicle and leaves out of that ban "los mecanismos de aviso que informan de la posición de los sistemas de vigilancia del
tráfico". A feature that senses, receives or interferes with a radar signal is out of scope, whoever asks for it.
Every radar shown keeps the source and attribution the feed gives it.

## Layout and build

- Swift, with a Swift package for the core (feed parsing, distances, alert logic) and a SwiftUI app plus a
  widget extension for the Live Activity.
- `App/project.yml` is the source of truth for the Xcode project. XcodeGen generates the `.xcodeproj`, which is
  never committed. Change `App/project.yml`, then run `xcodegen generate` in `App/`.
- Package tests: `swift test` at the repo root. App tests: `xcodebuild test` against the generated project
  on an iOS simulator.
- Heavy builds (full `xcodebuild`, simulator runs, repeated test loops) run on a Mac mini, never on the MacBook.
  The MacBook is for edits, git and single quick tests.
- Tests run offline against fixtures, never against the live feed.

## Merging

- CI green, CodeRabbit's review read and every finding fixed or answered, zero unresolved threads. Then squash.
- Conventional commits. PR titles say why, not a list of what changed.
- No AI attribution anywhere: no `Co-Authored-By` trailer, no "Generated with" line, in commits, PRs, comments
  or files.
- This repo is public. Nothing in it (files, commit messages, PR text) names a private server, its software or
  any deployment detail.

## Licence

GPL-3.0-or-later (see `LICENSE`). Every manifest added here carries the SPDX id `GPL-3.0-or-later`.
