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

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

## Where the tracker syncs

This repo is public, so its tracker syncs only to the private remote named by `sync.remote` in `.beads/config.yaml`. The block above says sync uses "your git remote". Here that never means this GitHub repo. Do not add it as a Dolt remote and do not push `refs/dolt/*` to it.
