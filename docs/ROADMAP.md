# Roadmap

## Before the first public release (0.x → 1.0)

- [ ] **Stable signing identity** – a self-signed certificate (free) keeps folder permissions and Keychain access
      across updates; Developer ID + notarization (Apple Developer Program) also removes the "Open Anyway" step.
- [ ] **Publish the GitHub repository** – the update feed (`SUFeedURL`) and the README links point there.
- [x] **Universal rclone** – official pinned release for Apple silicon and Intel.
- [x] **No Full Disk Access** – per-folder permission, verified through launchd.
- [x] **Automated tests** – unit tests and local-SFTP integration tests in CI.
- [ ] **Rendered UI review** – inspect the current design in the running app at minimum window size, light/dark mode and all locales.
- [ ] **Screenshots / short GIF** for the README.
- [ ] **GitHub Actions**: build the DMG on tag push and attach it to a release.
- [ ] **Signed update rehearsal** – publish a notarized test release, prepare the EdDSA appcast, and install it from an older version.
- [x] **Other-provider backup check** – OpenSSH (macOS Remote Login) and `rclone serve sftp` pass the full
      integration suite (`OPENSSH_KEY=… scripts/integration.sh`); CI runs the latter on every push.
- [ ] Try a Linux VPS and a Synology/QNAP NAS before the website launch (quota display, restricted shells).
- [x] **Onboarding flow** – a first-run assistant instead of pointing new users at Settings.
- [x] **Browser stop test** – cancelled uploads preserve unrelated remote files whose names resemble rclone partials
      (`--selftest`). An interrupted upload may leave its own partial file for manual cleanup.
- [x] **Host-key fingerprint confirmation** before the first connection (key setup, test, browser).

## Next

- [ ] **Edit in external app** – open a remote file in Photoshop/InDesign/…, re-upload on every save.
- [ ] Drag files from the browser straight into Finder (file promises); today: Download / Download to….
- [ ] Get Info: Unix permissions and owner, with chmod.
- [ ] Resume interrupted single-file uploads (currently a paused file restarts from zero).
- [ ] Multiple browser tabs/windows per server.

- [ ] Multiple backup jobs (several local folders → several remote folders).
- [ ] Bandwidth limit and "only on power adapter / only on Wi-Fi X" options.
- [x] Automatic update check (Sparkle); public installation awaits the signed update rehearsal above.
- [ ] Weekly integrity check (`rclone check --download` on a random sample).
- [ ] Email / webhook alert when no successful backup for N days.
- [ ] Browse the live backup (not only archived versions) and restore from it.
- [ ] Optional client-side encryption (rclone `crypt` remote).
- [ ] Launch at login toggle for the menu bar item.

## Ideas

- Support other SFTP targets and S3-compatible storage through rclone backends.
- Homebrew cask.
