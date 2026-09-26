<p align="center">
  <img src="docs/icon.png" width="128" alt="StorageBox Sync icon">
</p>

<h1 align="center">StorageBox Sync</h1>

<p align="center">
  A native macOS app for your <a href="https://www.hetzner.com/storage/storage-box/">Hetzner Storage Box</a> and other SFTP servers: a Cyberduck-style file browser, plus scheduled backups with version history — without ever deleting anything silently.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-orange">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

---

## Why

A Storage Box is one of the cheapest ways to keep a terabyte of work off-site. What's missing is a
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
- **Drag & drop upload** of files and whole folders from Finder; **download** to Downloads or any folder.
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
- **One-click SSH key setup** – enter your Storage Box password once; the app installs its own key and
  never stores the password.
- **Server-side checksums** – unchanged files are verified with `md5sum` on the box, so re-checking a
  few hundred GB does not re-upload anything.
- English and Croatian UI.

## How it works

The browser talks to a local `rclone rcd` process started by the app: it listens on `127.0.0.1` only, on a
random port with random per-session credentials, keeps SFTP connections open (so folders open quickly)
and runs uploads/downloads as jobs with live statistics. Servers are passed to rclone as in-memory
connection strings, so saved passwords never touch disk.

Backups:

```
~/Desktop/Projects  ──rclone sync──▶  box:/home/Projects            (exact mirror)
                                   └▶ box:/home/_versions/2026-09-26_2100/…
                                        (previous copies of changed + deleted files)
```

Each run is `rclone sync <local> <remote> --backup-dir <versions>/<timestamp>` over SFTP (port 23).
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
2. Open it. Current builds are ad-hoc signed – if macOS blocks the first launch, right-click the app →
   **Open**.
3. Grant **Full Disk Access** (System Settings → Privacy & Security). Scheduled runs happen in the
   background, where macOS cannot show a permission prompt for protected folders such as Desktop or
   Documents.

### Setting up the Storage Box

1. In Hetzner Console enable **SSH support** for the box. Note the server (`uXXXXXX.your-storagebox.de`)
   and username (`uXXXXXX`).
2. In the app → **Settings**: enter server and username (port `23`), open *First-time setup*, enter your
   password and click **Install key**. Then **Test connection**.
3. Choose the local folder, the destination folder (e.g. `/home/Projects`) and the versions folder
   (e.g. `/home/_versions`). Save.
4. Recommended: run **Preview changes** once, then **Back up now**.
5. Recommended: also enable **automatic snapshots** for the box in Hetzner Console – an independent
   second layer that protects against anything that goes wrong on the client side.

The first backup of an existing remote copy can take a while: every file is compared by checksum once.
Later runs only look at what changed.

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

**Does it work with other SFTP servers?**
Probably, as long as the server allows `md5sum` over SSH. It is built and tested against Hetzner Storage
Boxes.

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
