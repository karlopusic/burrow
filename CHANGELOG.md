# Changelog

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
