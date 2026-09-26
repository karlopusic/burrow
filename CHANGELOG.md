# Changelog

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
