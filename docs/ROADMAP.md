# Roadmap

## Before the first public release (0.x → 1.0)

- [ ] **Developer ID signing + notarization** – removes the Gatekeeper warning and keeps Full Disk Access
      across updates (ad-hoc signatures change on every build).
- [ ] **Screenshots / short GIF** for the README.
- [ ] **GitHub Actions**: build the DMG on tag push and attach it to a release.
- [ ] **Onboarding flow** – a first-run assistant instead of pointing new users at Settings.
- [x] **Stop test** – interrupted uploads leave no partial files (backup + browser, covered by `--selftest`).
- [ ] **Host-key fingerprint confirmation** during SSH key setup (currently trust-on-first-use).

## Next

- [ ] **Edit in external app** – open a remote file in Photoshop/InDesign/…, re-upload on every save.
- [ ] Drag files from the browser straight into Finder (file promises); today: Download / Download to….
- [ ] Get Info: Unix permissions and owner, with chmod.
- [ ] Resume interrupted single-file uploads (currently a paused file restarts from zero).
- [ ] Multiple browser tabs/windows per server.

- [ ] Multiple backup jobs (several local folders → several remote folders).
- [ ] Bandwidth limit and "only on power adapter / only on Wi-Fi X" options.
- [ ] Automatic update check (Sparkle).
- [ ] Weekly integrity check (`rclone check --download` on a random sample).
- [ ] Email / webhook alert when no successful backup for N days.
- [ ] Browse the live backup (not only archived versions) and restore from it.
- [ ] Optional client-side encryption (rclone `crypt` remote).
- [ ] Launch at login toggle for the menu bar item.

## Ideas

- Support other SFTP targets and S3-compatible storage through rclone backends.
- Homebrew cask.
