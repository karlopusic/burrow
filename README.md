<p align="center">
  <img src="docs/icon.png" width="128" alt="StorageBox Sync icon">
</p>

<h1 align="center">StorageBox Sync</h1>

<p align="center">
  A native macOS app for SFTP storage servers: a file browser and scheduled backups with version history. Hetzner Storage Box is available as a setup preset.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-orange">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

---

## Why

An SFTP storage server is a practical place to keep work off-site. What's missing is a
simple, trustworthy way for a Mac user to *use* it as a backup:

- **Plain sync is not a backup.** Delete a folder by accident (or get hit by ransomware) and a naive
  sync happily propagates the damage to your only copy.
- **Command-line tools work, but nobody checks them.** A cron job that silently failed three weeks ago
  looks exactly like one that works.

StorageBox Sync wraps [rclone](https://rclone.org) in a small menu-bar app that answers the only
questions that matter: *When was my last good backup? What changed? Can I get the old version back?*

## Features

### File browser

- **Bookmarks** for any number of SFTP servers (Storage Box, your own VPS, client servers) – SSH key or
  password (stored in the macOS Keychain).
- **Browse** in list or icon view, sort by name/date/size/kind, path bar, back/forward, hidden files toggle,
  **recursive search**.
- **Quick Look** any remote file with the space bar.
- **Drag & drop upload** of files and whole folders from Finder; right-click to download one file, a selection, or a folder to a location you choose.
- **File history in the browser** for files in the configured backup: preview, open a local copy, or download an archived version.
- **Transfer queue** with live progress, speed and ETA, pause/resume, cancel, retry and history.
- **File management**: new folder, rename, duplicate, cut/copy/paste, Get Info (incl. folder size), copy path.
- **Safe delete**: "Move to Trash" moves items into a dated trash folder on the server, and **Put Back**
  restores them to where they were. Uploading over an existing file offers *Keep Both*, *Replace* (the old
  copy goes to the trash) or *Skip*. Permanent deletion only happens inside the trash, after confirmation.

### Backup

- **Scheduled backups** via a LaunchAgent – daily or weekly, runs even when the app is closed, catches
  up after sleep.
- **Version history** – files you change or delete locally are moved into a dated archive folder on the
  box instead of being overwritten. Old versions are pruned after a configurable retention period.
- **Safety brakes**
  - blocks a run if the local file count suddenly drops (unmounted drive, accidental delete, ransomware)
    until you confirm it,
  - caps how many files a single run may archive,
  - refuses to run on an empty or unreadable source folder.
- **Preview changes** – a dry-run that lists exactly what would be uploaded and what would be archived.
- **Restore** single files or whole versions into `~/Downloads` – your working folder is never overwritten.
- **Live progress**, run history with per-run logs, macOS notifications, Storage Box quota.
- **SSH key setup** – use an existing key, or install a dedicated key on a compatible server; the app
  never stores the password.
- **Optional server-side checksums** – enable remote shell commands on servers that permit them. Generic SFTP connections work without an SSH shell.
- **In-app updates** through Sparkle for signed public releases, with automatic checks and a manual check in About.
- English, Croatian and German UI – English by default, switchable in Backup Settings → Language.

## How it works

The browser talks to a local `rclone rcd` process started by the app: it listens on `127.0.0.1` only, on a
random port with random per-session credentials, keeps SFTP connections open (so folders open quickly)
and runs uploads/downloads as jobs with live statistics. Folder listings are cached (bounded LRU, persisted
in `~/Library/Caches`) and refreshed in the background, and subfolders are prefetched, so navigation is instant
even on a slow connection; anything that could overwrite data re-checks the server first. Servers are passed to rclone as in-memory
connection strings, so saved passwords never touch disk.

Backups:

```
~/Desktop/Projects  ──rclone sync──▶  box:/home/Projects            (exact mirror)
                                   └▶ box:/home/_versions/2026-09-26_2100/…
                                        (previous copies of changed + deleted files)
```

Each run is `rclone sync <local> <remote> --backup-dir <versions>/<unique-run-id>` over SFTP (the server's configured port).
The app itself is a thin, auditable layer: configuration, scheduling, safety checks, log parsing and a UI.
All state lives in:

| What | Where |
|---|---|
| Settings, run history, generated rclone config | `~/Library/Application Support/StorageBox Sync/` |
| One log file per run | `~/Library/Logs/StorageBox Sync/` |
| Schedule | `~/Library/LaunchAgents/hr.push.storageboxsync.plist` |
| SSH key | `~/.ssh/storageboxsync_ed25519` |
| Server bookmarks, transfer history | `~/Library/Application Support/StorageBox Sync/` |
| Server trash | `<login folder>/.sbs-trash/<date>/…` (configurable per server) |

## Install

1. Download the latest `StorageBox-Sync-x.y.z.dmg` from [Releases](../../releases) and drag the app to
   **Applications**.
2. Open it. Development builds are ad-hoc signed; public release builds need Developer ID signing and notarization.
3. Grant **Full Disk Access** (System Settings → Privacy & Security). Scheduled runs happen in the
   background, where macOS cannot show a permission prompt for protected folders such as Desktop or
   Documents.

### Setting up an SFTP server

1. Open the setup assistant. Enter the SFTP host, port and username. Hetzner users can select the
   **Hetzner Storage Box** preset, which fills in its host format and port 23.
2. Confirm the server fingerprint and choose an SSH key accepted by the server. Scheduled backups require
   key authentication without a passphrase. The built-in key installer requires writable `~/.ssh/authorized_keys` on the server.
3. Choose the local folder, a dedicated backup folder, and a separate versions folder. Save.
4. Recommended: run **Preview changes** once, then **Back up now**.
5. If your provider offers server-side snapshots, enable them as an independent recovery layer.

The first backup of an existing remote copy can take a while. Servers with SSH shell access can use
server-side checksums; otherwise rclone compares file size and modification time.

## Build from source

Requirements: macOS 14+, Xcode or the Command Line Tools, `brew install rclone`.

```sh
git clone https://github.com/karlopusic/storagebox-sync.git
cd storagebox-sync
scripts/build.sh                 # → dist/StorageBox-Sync-<version>.dmg (universal binary)
```

`Package.swift` lets you open the project in Xcode for editing; the app bundle itself is assembled by
`scripts/build.sh`. See [CONTRIBUTING.md](CONTRIBUTING.md) for details and [docs/ROADMAP.md](docs/ROADMAP.md)
for what's planned.

## FAQ

**Does it work with other storage providers?**
The app supports SFTP servers, including Storage Box services from other providers. Browsing accepts SSH key
or password authentication. Unattended backups require SSH key authentication and server-side rename/move
support for the version archive. Hetzner is the current end-to-end tested provider; other providers need
compatibility testing before they are listed as verified.

**Why rclone and not restic/Borg?**
Those are excellent, but they store data in their own repository format. StorageBox Sync keeps a plain,
browsable copy of your files on the box – you can open any file from any machine without special tools.
If you need encryption and deduplication, restic or Borg is the better choice.

**Is my password stored?**
No. It is used once to install an SSH key and is kept only in memory and in a temporary file that is
deleted immediately afterwards.

**What if I delete something by mistake?**
The deleted files are moved into the versions folder on the next run and can be restored from the
**Versions** tab until the retention period expires. If a large share of files disappears at once, the
backup is blocked until you confirm it.

## License

MIT © 2026 [Karlo Pušić](https://push.hr). StorageBox Sync bundles rclone, which is MIT-licensed – see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Not affiliated with Hetzner Online GmbH.
