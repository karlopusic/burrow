# Contributing

## Data-safety rules

Burrow writes to people's only off-site copy of their files. Every change must keep these rules:

- Any remote write must be additive or go through `--backup-dir`. Never add an operation that deletes or overwrites
  data on the server outside the versions folder.
- Browser "Delete" goes through `BrowserModel.trash()`. Permanent deletes happen only inside the trash, after
  confirmation.
- The listing cache is for display only. Conflict checks before rename, move or upload use a fresh `list()`, never
  `items` or the cache. Browser transfers and moves run with rclone's `IgnoreExisting`.
- Names written to the server are Unicode NFC (`String.nfc`, rclone `--local-unicode-normalization`). An NFD spelling
  of the same name is a second file on SFTP. Conflict checks compare `RPath.conflictKey` (NFC, ignoring case, because
  macOS and Windows servers ignore case). `String ==` hides the NFC/NFD difference, so tests compare `unicodeScalars`.
- rclone rc `operations/list` returns paths relative to the fs root (already including the listed folder), unlike
  `rclone lsjson`.
- `launchctl bootout` kills a running scheduled backup: reinstall the agent only when no run is active.
- Never test against real backup data. Use a throw-away source folder and remote path (see below).
- Every user-facing string needs an entry in `Resources/hr.lproj` and `Resources/de.lproj/Localizable.strings`.
  No string ternaries in `Text()`.
- The app enum is `AppInfo`. Never name a type `App` (it clashes with `SwiftUI.App`).
- Build only with `scripts/build.sh` (`swiftc -swift-version 5`). With the Command Line Tools only, compile against
  the macOS 26.x SDK; SDK 27 needs the SwiftUI macro plugin from full Xcode.
- Before committing, run `scripts/test.sh`; after `scripts/build.sh`, also `scripts/integration.sh`. After touching
  `BrowserModel`, `Transfers` or `RcloneDaemon`, run `--selftest` as well. All checks must pass.
- Releases follow [RELEASING.md](RELEASING.md). The Sparkle private key and the code-signing key never enter the
  repository.

## Project layout

```
Sources/Burrow/
  App/    BurrowApp.swift   entry point: `--run` / `--dry-run` = headless, otherwise the SwiftUI app
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
          Install.swift             where the app runs from (Applications / DMG / translocated), Move to Applications
          AccessCheck.swift         `--check-access`: can a launchd-started run read the local folder?
          Updates.swift             Sparkle updater (off for development builds)
          Shell.swift, Paths.swift  process helpers, file locations, L() localization helper
  UI/     AppModel.swift            observable state + actions for the views
          BrowserModel.swift        one server browser: listing, search, rename/move, trash, uploads/downloads
          Components.swift          shared visuals: card(), IconBadge, StatTile, StatusPill, Toast
          HostKeyViews.swift        HostVerifier + fingerprint confirmation sheet
          OnboardingView.swift      first-run setup assistant
          *View.swift               Browser, Transfers, bookmark editor, backup Overview/Versions/Settings
Resources/                          Info.plist template, icon, en/hr Localizable.strings
Tests/UnitTests.swift               unit tests (no network), run by scripts/test.sh
scripts/toolchain.sh                SDK choice + pinned, checksum-verified Sparkle and universal rclone (shared)
scripts/build.sh                    compiles, assembles the .app, bundles rclone and Sparkle, signs, builds the DMG
scripts/test.sh                     unit tests in a throw-away home folder
scripts/integration.sh              selftest + backup scenarios against a local `rclone serve sftp`
```

## Tests

```sh
scripts/test.sh                                  # unit tests, seconds, no network
scripts/build.sh && scripts/integration.sh       # end-to-end against a throw-away local SFTP server
OPENSSH_KEY=~/.ssh/test_key scripts/integration.sh   # same, against this Mac's OpenSSH (Remote Login)
```

For the OpenSSH run, add a dedicated test key to `~/.ssh/authorized_keys`, ideally restricted with
`from="127.0.0.1,::1"`, and remove it afterwards. The tests create an exclusive `_burrow_it_<random>` folder in your home folder
and delete it again. On an unthrottled local server the cancel test is reported as SKIP: a 300 MB upload
finishes before the first progress update.

Both run in CI on every push. `integration.sh` covers the browser self-test and the backup safety scenarios
(upload, changed file → versions, deleted file → versions, failed run preserves unrelated remote files,
preview changes nothing, safety block, "Run anyway", NFC names, empty source). It never touches real backup data.

## Building

```sh
scripts/build.sh                   # dist/Burrow-$(cat VERSION).dmg
VERSION=0.2.0 scripts/build.sh
SIGN_ID="Developer ID Application: …" scripts/build.sh
SIGN_ID="Developer ID Application: …" NOTARY_PROFILE="burrow" scripts/build.sh
```

With only the Command Line Tools installed, the script compiles against the newest macOS **26.x** SDK:
the macOS 27 SDK implements `@State` and friends as macros whose compiler plugin ships only with full
Xcode. With Xcode installed, the current SDK is used.

The build downloads pinned Sparkle 2.10.0 into ignored `.build/vendor/` and checks its SHA-256 before
using it. The public signing and update process is in [RELEASING.md](RELEASING.md).

## Self-test (browser + transfers)

Runs browser and transfer checks against a disposable SFTP path inside a random `_burrow_selftest_<UUID>` folder that it
creates and removes again (uploads, conflicts, rename, move, trash / put back, Quick Look, downloads, cancel safety):

```sh
"build/Burrow.app/Contents/MacOS/Burrow" --selftest <host> <port> <user> <keyfile>
```

Run it before every commit that touches `BrowserModel`, `Transfers` or `RcloneDaemon`.

## Testing a backup change safely

Never point a development build at real data first. Create a throw-away source folder and a throw-away
remote path (e.g. `/home/_burrow_test/dst` and `/home/_burrow_test/_versions`), then run the binary directly:

```sh
"build/Burrow.app/Contents/MacOS/Burrow" --dry-run
"build/Burrow.app/Contents/MacOS/Burrow" --run
```

Check at least: new file uploaded · changed file → old copy in versions · deleted file → moved to versions ·
safety block when files disappear · "Run anyway" · stop mid-run.

Note: builds are ad-hoc signed, so macOS treats every rebuild as a new app – Full Disk Access has to be
granted again after installing a new build.

## Running a dev build safely

The LaunchAgent of a real installation may point at `build/`, and a launched build reinstalls the agent. To
look at UI changes without touching real settings or the real schedule, start the binary with a throw-away home:

```sh
CFFIXED_USER_HOME=/tmp/burrow-home "build/Burrow.app/Contents/MacOS/Burrow"
launchctl bootout gui/$(id -u)/hr.push.burrow.dev   # afterwards
```

Config, bookmarks, logs and `known_hosts` then live under that folder, and the agent gets the label
`hr.push.burrow.dev`. UserDefaults are still shared with the real app.

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
