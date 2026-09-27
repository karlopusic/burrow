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
          RcloneDaemon.swift        long-running `rclone rcd` + JSON API client used by the browser
          Transfers.swift           transfer queue (async rclone jobs, progress polling, pause/cancel)
          Bookmark.swift            server bookmarks, Keychain passwords, remote path helpers
          HostKeys.swift            host-key scan, SHA256 fingerprints, known_hosts trust
          DirCache.swift            bounded per-server cache of folder listings (memory LRU + ~/Library/Caches)
          SelfTest.swift            `--selftest`: end-to-end test of browser + transfers on a real server
          Shell.swift, Paths.swift  process helpers, file locations, L() localization helper
  UI/     AppModel.swift            observable state + actions for the views
          BrowserModel.swift        one server browser: listing, search, rename/move, trash, uploads/downloads
          Components.swift          shared visuals: card(), IconBadge, StatTile, StatusPill, Toast
          HostKeyViews.swift        HostVerifier + fingerprint confirmation sheet
          OnboardingView.swift      first-run setup assistant
          *View.swift               Browser, Transfers, bookmark editor, backup Overview/Versions/Settings
Resources/                          Info.plist template, icon, en/hr Localizable.strings
scripts/build.sh                    compiles, assembles the .app, bundles rclone and Sparkle, signs, builds the DMG
```

## Building

```sh
scripts/build.sh                   # dist/StorageBox-Sync-$(cat VERSION).dmg
VERSION=0.2.0 scripts/build.sh
SIGN_ID="Developer ID Application: …" scripts/build.sh
SIGN_ID="Developer ID Application: …" NOTARY_PROFILE="storagebox-sync" scripts/build.sh
```

With only the Command Line Tools installed, the script compiles against the newest macOS **26.x** SDK:
the macOS 27 SDK implements `@State` and friends as macros whose compiler plugin ships only with full
Xcode. With Xcode installed, the current SDK is used.

The build downloads pinned Sparkle 2.10.0 into ignored `.build/vendor/` and checks its SHA-256 before
using it. The public signing and update process is in [RELEASING.md](RELEASING.md).

## Self-test (browser + transfers)

Runs 30 checks against a real SFTP server inside a random `_sbs_selftest_<n>` folder that it creates and
removes again (uploads, conflicts, rename, move, trash / put back, Quick Look, downloads, cancel cleanup):

```sh
"build/StorageBox Sync.app/Contents/MacOS/StorageBoxSync" --selftest <host> <port> <user> <keyfile>
```

Run it before every commit that touches `BrowserModel`, `Transfers` or `RcloneDaemon`.

## Testing a backup change safely

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

## Running a dev build safely

The LaunchAgent of a real installation may point at `build/`, and a launched build reinstalls the agent. To
look at UI changes without touching real settings or the real schedule, start the binary with a throw-away home:

```sh
CFFIXED_USER_HOME=/tmp/sbs-home "build/StorageBox Sync.app/Contents/MacOS/StorageBoxSync"
launchctl bootout gui/$(id -u)/hr.push.storageboxsync.dev   # afterwards
```

Config, bookmarks, logs and `known_hosts` then live under that folder, and the agent gets the label
`hr.push.storageboxsync.dev`. UserDefaults are still shared with the real app.

## Localization

Keys are the English source strings. SwiftUI literals (`Text("…")`, `Button("…")`) are looked up
automatically; strings built in code use `L("…", args)`. Interpolated SwiftUI strings become format keys
(`Int` → `%lld`, everything else → `%@`); `L()` keys use `%ld` / `%@`. Add every new string to
`Resources/hr.lproj/Localizable.strings` **and** `Resources/de.lproj/Localizable.strings`;
`scripts/check_strings.py` lists anything missing per language. Strings passed positionally to helper views
(e.g. `header("…", "…")` in the setup assistant) aren't detected – add those by hand.

The UI language is `AppLanguage` (Paths.swift): English unless changed in Settings, applied at the very start
of `main()` by writing `AppleLanguages` into the app's defaults, so GUI and headless runs agree.

A string passed through a ternary (`Text(flag ? "a" : "b")`) is inferred as `String` and **not**
localized – write `flag ? Text("a") : Text("b")` instead.

## Commit style

Conventional commits (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`).
