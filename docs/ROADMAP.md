# Roadmap

## Before the first public release (0.x → 1.0)

- [ ] **Developer ID signing + notarization** – removes the Gatekeeper warning and keeps Full Disk Access
      across updates (ad-hoc signatures change on every build).
- [ ] **Screenshots / short GIF** for the README.
- [ ] **GitHub Actions**: build the DMG on tag push and attach it to a release.
- [ ] **Onboarding flow** – a first-run assistant instead of pointing new users at Settings.
- [ ] **Stop test** – confirm SIGTERM mid-upload leaves no partial files on the box.
- [ ] **Host-key fingerprint confirmation** during SSH key setup (currently trust-on-first-use).

## Next

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
