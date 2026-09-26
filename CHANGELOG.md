# Changelog

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
