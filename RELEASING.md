# Public release

Do not publish a development DMG: `scripts/build.sh` uses an ad-hoc signature unless `SIGN_ID` is set.

1. Review the working tree and remove secrets and unrelated files. Run `python3 -B scripts/check_strings.py` and `git diff --check`.
2. Build and test on disposable local and SFTP paths. Follow `CONTRIBUTING.md` for `--selftest` and the backup safety scenarios. Test at least one non-Hetzner SFTP server before claiming it is verified.
3. Set `VERSION` to the new version and record release notes in `CHANGELOG.md`. Every release must increase `CFBundleVersion` (currently equal to `VERSION`).
4. Build the release on a Mac with a Developer ID Application certificate and a configured notarytool keychain profile:

   ```sh
   SIGN_ID="Developer ID Application: …" NOTARY_PROFILE="burrow" scripts/build.sh
   ```

   The build signs the app, bundled rclone and Sparkle helpers with Hardened Runtime, notarizes the DMG and staples its ticket. Verify the app and DMG with `codesign`, `spctl` and `xcrun stapler validate` on a clean Mac.
5. Publish the DMG as a GitHub release asset under tag `v<VERSION>`. Do not point the appcast at a missing asset.
6. Run `zsh scripts/prepare_update.sh`. It requires the notarized DMG, signs the archive using the `hr.push.storageboxsync` Sparkle key in the login Keychain (named after the former app name; it matches `SUPublicEDKey`), and prepends the new entry to `appcast.xml`. The private key must be backed up securely outside this repository. Never commit or print its exported value.
7. Review the appcast URL, EdDSA signature, file size and version. Commit and publish the appcast only after the DMG asset is accessible. Test an installed older version updating to the new one, including while no backup is running and while a scheduled backup is active.

The appcast is hosted from `main` at `https://raw.githubusercontent.com/karlopusic/burrow/main/appcast.xml`. The initial empty feed is intentional until the first signed public release.
