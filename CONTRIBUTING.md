# Contributing

Thanks for helping. Radares Anunciados warns a driver before announced speed radars in Spain, from published positions only.

## Before you start

- Read [AGENTS.md](AGENTS.md) for the layout, the build and the legal line, and [docs/DESIGN.md](docs/DESIGN.md) for why the app works the way it does.
- Open an issue first for anything bigger than a small fix, so we can agree on the approach before you write it.
- A feature that senses, receives or interferes with a radar signal is out of scope. The app only reads positions that were published in advance (RGC art. 18.3).

## Build and test

```bash
swift test                                  # the RadaresCore package, on a Mac
xcodegen generate --spec App/project.yml    # then open App/RadaresAnunciados.xcodeproj
```

Tests run offline against fixtures, never against the live feed. Every new rule gets a test, and the test must fail when the rule is broken: break it once on purpose before you open the pull request.

## Pull requests

- Conventional commits (`fix:`, `feat:`, `docs:`). The title says why the change is needed, not a list of what changed.
- One topic per pull request. Keep unrelated clean-ups out.
- User-facing text is Spanish first, with correct accents, and an English translation in `App/Sources/Localizable.xcstrings`.
- Every source file, script and manifest you add carries `SPDX-License-Identifier: GPL-3.0-or-later`.

## Licence of your contribution

The code is GPL-3.0-or-later. [NOTICE](NOTICE) proposes an additional permission under section 7 that would allow distribution through Apple's App Store and TestFlight; it is not in effect until the maintainer adopts it. By opening a pull request you agree that your contribution is licensed under GPL-3.0-or-later and, once adopted, under that additional permission too. Without it the app could not be published on the App Store.
