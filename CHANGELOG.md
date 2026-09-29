# Changelog

## Unreleased

Release preparation: the app is now **Burrow**, plus security fixes, no Full Disk Access, Intel support and
automated tests.

- **Renamed to Burrow** (bundle `hr.push.burrow`), so the name isn't tied to one storage provider. The first launch
  moves an existing StorageBox Sync installation over: settings, run history, logs, server bookmarks, Keychain
  passwords, preferences and the schedule. It waits while an old backup is still running. The old folders are kept
  as "… (migrated)". New server bookmarks use `.burrow-trash`; existing ones keep their trash folder.

- **Intel Macs**: the bundled rclone is now the official universal release (Apple silicon + Intel), pinned and
  checksum-verified. Before, it was a copy of the build Mac's Homebrew rclone and didn't run on Intel.
- **Security**: the local rclone daemon's credentials are passed through the environment instead of the command
  line, where other users on the same Mac could read them.
- **Security**: installing an SSH key no longer replaces the server's `authorized_keys` when reading it fails
  (timeout, permissions). The setup stops with an error instead, so existing keys are never lost.
- Line breaks in the server or user field can no longer inject rclone options.
- **Data safety in the file browser**: a case-only rename ("Report.pdf" → "report.pdf") on a server that ignores
  case (macOS, Windows) deleted the file; it now goes through a temporary name, and name conflicts ignore case.
  Uploads, copies and moves never overwrite a server file, even one that appeared after the conflict check, and
  stop with an error when the folder can't be listed. "Empty Trash" can't run on an empty, root or backup folder
  set as trash. "Put Back" no longer deletes items whose origin wasn't recorded, and two deletes in the same
  second no longer collide.
- **First backup after a folder change**: when the local or server folder changes (or on a new Mac), the first
  run compares with the files already in the server folder and waits for "Run anyway" if the local folder has
  far fewer. Settings warns when a folder changes; the setup assistant says that moved files are deleted after the
  retention period. Backup and versions folders written as one absolute and one relative path are checked for
  overlap too.
- **Missed backups catch up at login**: a scheduled time missed while the Mac was shut down now runs at the next
  login (launchd only caught up after sleep).
- Stop works while a backup is still counting files. Pruning old versions no longer trusts the Mac's clock alone,
  so a clock that jumps ahead can't delete the whole archive. Quitting asks first while transfers run; transfers
  whose rclone job is lost are marked failed instead of running forever. `rcd.log` is rotated at 5 MB.
- **No Full Disk Access needed.** For folders in Desktop, Documents, Downloads, iCloud Drive or on external/network
  volumes, the app checks access the same way a scheduled backup reads the folder (through launchd), and macOS asks
  once for that folder only.
- **Move to Applications**: when the app runs from the disk image or a translocated download, it offers to move
  itself, and it no longer installs a schedule pointing at a path that disappears.
- Notifications come from Burrow instead of "Script Editor".
- Provider-neutral setup: "SFTP server" is the default in the setup assistant, and the fingerprint hint explains
  where any provider (or your own server) shows it.
- Development builds don't check for updates ("Check for Updates…" is hidden).
- Unit tests (`scripts/test.sh`) and integration tests against a local SFTP server (`scripts/integration.sh`),
  both in CI. The integration suite also runs against OpenSSH (verified with macOS Remote Login). `SECURITY.md`, issue templates, clearer third-party notices and password FAQ.

## 0.3.0 – 2026-09-27

Setup assistant, host-key verification and a visual redesign.

- **Setup assistant** on first launch: server → confirm fingerprint → SSH key → folders → schedule, then a
  recommended preview. Warns before mirroring into a box folder that already has content, and when Full Disk
  Access is needed. Can be reopened from the "Finish setup" banner.
- **Host-key verification** instead of trust-on-first-use: the server's SHA256 fingerprints are shown and must be
  confirmed before anything is written to `~/.ssh/known_hosts` (key installation, Test Connection, browser).
  The browser explains unverified and changed host keys instead of showing the raw ssh error.
- Folder safety check (Settings + assistant): the whole box or `/home` can't be the backup folder, and the
  versions folder must be outside it.
- Redesigned overview: status hero with actions, key figures (next backup, box usage with gauge, retention),
  source → destination card, history with status pills. New "overdue" state when a scheduled run is >12 h late.
- Sidebar with colored icons, backup-destination marker and "Add Server…" footer; animated toast;
  system-style empty states in browser, transfers and versions; dashed drop target in the browser.
- Menu bar: next backup time and "Preview changes".
- **German translation**, and a language picker (English / Hrvatski / Deutsch) in Backup Settings. The app now
  starts in English by default instead of following the system language; scheduled runs use the same choice.
- Dev instances started with `CFFIXED_USER_HOME` use their own LaunchAgent label.
- Fixes from the rendered UI review: the browser shows a spinner instead of "This folder is empty" while
  connecting; browser, Transfers and Versions fill the window instead of floating mid-window when empty;
  wider Name column at the minimum window size; `--selftest` no longer leaves a `lastPath` default behind.
- Backups set up before server bookmarks existed show their real connection in Backup Settings instead of
  "Choose…", and Settings names the servers left out because they use a password.
- Version-history markers appear for every saved server on the backup's account (same host, port and user),
  not only the explicitly linked one.
- The Keychain password is read once per launch instead of on every connection (one prompt instead of several).
- File names are uploaded in Unicode NFC (backup and browser). A letter like "š" can be stored as one character
  or as "s" + a combining caron; the server treats those as two different names, which left folders on the box
  twice (and rclone skipping one copy of each). Conflict checks treat both spellings as the same name, and a
  backup that meets such a pair on the server now says so in its result.

## 0.2.1 – 2026-09-26

Faster browsing.

- Folder listings are cached (LRU: 1,500 folders in memory, the 400 most recent on disk) and shown instantly,
  then refreshed in the background (stale-while-revalidate)
- Subfolders of the current folder are prefetched (3 at a time, up to 40), so opening them is instant
- SFTP connections stay open for 30 minutes instead of 60 seconds (a reconnect costs several seconds)
- Servers are connected and the last visited folder is restored at launch
- File icons and kinds are looked up once per extension
- Conflict checks (rename, move, upload) always use a fresh listing, never the cache

## 0.2.0 – 2026-09-26

File browser for SFTP servers, in the spirit of Cyberduck.

- Server bookmarks (SSH key or Keychain password), sidebar layout
- Browser: list/icon view, sorting, path bar, back/forward, hidden files, recursive search, Quick Look
- Drag & drop upload of files and folders, download to Downloads or a chosen folder
- Transfer queue with progress, speed, ETA, pause/resume, cancel, retry, history
- New folder, rename, duplicate, cut/copy/paste, Get Info with folder size, copy path
- Server-side trash with Put Back; upload conflicts: Keep Both / Replace (old copy to trash) / Skip
- Backups use a saved server; lock/temp files of open documents (`*.idlk`, `~$*`, `.~lock.*#`) are skipped
- `--selftest` end-to-end test, `scripts/check_strings.py` translation check

## 0.1.0 – 2026-09-26

First version, grown out of a private backup script for a design studio's project archive.

- Scheduled `rclone sync` to a Hetzner Storage Box with dated version archive (`--backup-dir`)
- Safety brakes: file-count drop block, `--max-delete`, empty/unreadable source guard
- Preview (dry-run) with filterable change list
- Restore single files or whole versions into `~/Downloads`
- Live progress, run history, per-run logs, notifications, box quota
- One-click SSH key installation
- English + Croatian UI
- Bundled rclone, universal binary, DMG build script
