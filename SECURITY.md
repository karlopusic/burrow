# Security policy

Burrow handles SSH keys, server passwords and backups, so security reports are welcome and taken seriously.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Instead, use GitHub's
[private vulnerability reporting](../../security/advisories/new) for this repository.

Include what you found, the steps to reproduce it and the app version (About Burrow). You'll get an answer
within a few days. Once a fix is released, you'll be credited in the changelog unless you prefer not to be.

## Supported versions

Only the latest release receives security fixes. The app updates itself (Sparkle, EdDSA-signed updates).

## Design notes for reviewers

- Server passwords are stored only in the macOS Keychain. They're passed to rclone in memory, never on the command
  line or in files that persist.
- The local rclone daemon listens on `127.0.0.1` on a random port. Its random credentials are passed through the
  environment, not the command line, so other users on the Mac can't read them from the process list.
- Host keys must be confirmed by fingerprint before the first connection. After that, a changed host key blocks the
  connection.
- Backups never delete or overwrite files on the server outside the versions folder: changed and deleted files are
  moved there (`rclone sync --backup-dir`).
- Updates are verified with an EdDSA signature (Sparkle) before they're installed.
