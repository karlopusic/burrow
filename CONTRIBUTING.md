# Contributing

## Project layout

```
Sources/StorageBoxSync/
  App/    StorageBoxSyncApp.swift   entry point: `--run` / `--dry-run` = headless, otherwise the SwiftUI app
  Core/   Runner.swift              one backup or preview run (rclone sync + safety checks)
          Config.swift              config.json model; generates rclone.conf from it
          Status.swift              status.json (run history, running job) with flock-protected writes
          LogParser.swift           progress / summary / preview extracted from rclone's log
          Agent.swift               LaunchAgent install for scheduled runs
          KeySetup.swift            one-time SSH key installation using the account password
          Migration.swift           import from the pre-release prototype ("SIM Backup")
          Shell.swift, Paths.swift  process helpers, file locations, L() localization helper
  UI/     AppModel.swift            observable state + actions for the views
          *View.swift               Overview, Versions, Settings
Resources/                          Info.plist template, icon, en/hr Localizable.strings
scripts/build.sh                    compiles, assembles the .app, bundles rclone, signs, builds the DMG
```

## Building

```sh
scripts/build.sh                   # dist/StorageBox-Sync-$(cat VERSION).dmg
VERSION=0.2.0 scripts/build.sh
SIGN_ID="Developer ID Application: …" scripts/build.sh
```

With only the Command Line Tools installed, the script compiles against the newest macOS **26.x** SDK:
the macOS 27 SDK implements `@State` and friends as macros whose compiler plugin ships only with full
Xcode. With Xcode installed, the current SDK is used.

## Testing a change safely

Never point a development build at real data first. Create a throw-away source folder and a throw-away
remote path (e.g. `/home/_sbs_test/dst` and `/home/_sbs_test/_versions`), then run the binary directly:

```sh
"build/StorageBox Sync.app/Contents/MacOS/StorageBoxSync" --dry-run
"build/StorageBox Sync.app/Contents/MacOS/StorageBoxSync" --run
```

Check at least: new file uploaded · changed file → old copy in versions · deleted file → moved to versions ·
safety block when files disappear · "Run anyway" · stop mid-run.

Note: builds are ad-hoc signed, so macOS treats every rebuild as a new app – Full Disk Access has to be
granted again after installing a new build.

## Localization

Keys are the English source strings. SwiftUI literals (`Text("…")`, `Button("…")`) are looked up
automatically; strings built in code use `L("…", args)`. Interpolated SwiftUI strings become format keys
(`Int` → `%lld`, everything else → `%@`); `L()` keys use `%ld` / `%@`. Add every new string to
`Resources/hr.lproj/Localizable.strings`.

A string passed through a ternary (`Text(flag ? "a" : "b")`) is inferred as `String` and **not**
localized – write `flag ? Text("a") : Text("b")` instead.

## Commit style

Conventional commits (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`).
