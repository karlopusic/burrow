# Roadmap

Where Burrow is heading after 0.4, the first public beta. Plans can change; data safety always comes before new
features. Ideas and requests are welcome in the [issues](https://github.com/karlopusic/burrow/issues).

## 0.4.x – Trust and polish

- A notification when no backup has succeeded for longer than planned.
- A weekly integrity check: a sample of backed-up files is downloaded and compared with your Mac.
- "Test a restore" to prove with one click that your files come back.
- "Copy diagnostics" for bug reports, with server names and paths removed.
- Accessibility (VoiceOver, keyboard navigation) and visual polish.

## 0.5 – Multiple backups

- Back up several folders, each to its own server and folder, with its own schedule and retention.
- Bandwidth limit, "only on power adapter" and "not on mobile hotspots or low-data networks".
- Edit the list of excluded files in the app.

## 0.6 – S3-compatible storage

- Backblaze B2, Wasabi, Cloudflare R2, Amazon S3, Hetzner Object Storage and MinIO, alongside SFTP.
- Old versions kept by the bucket's own versioning.
- With Object Lock, versions can't be deleted for a set time, not even from your Mac. That protects the backup
  against ransomware and mistakes.

## 0.7 – Optional encryption

- End-to-end encryption per backup, off by default, with a recovery key you save when you turn it on.

## Along the way

- Open a server file in any app and save it straight back.
- Drag files from the browser into Finder.
- Resume interrupted uploads, several browser tabs, file permissions in Get Info.
- Launch at login.
- Guides for popular providers and NAS devices.

## Not planned

- Deduplication or a special repository format. Burrow keeps plain files you can open anywhere; if you need
  deduplication, [restic](https://restic.net) or [Borg](https://www.borgbackup.org) are the better tools.
- Consumer clouds (Google Drive, Dropbox, OneDrive), which have their own sync apps.
- Windows or Linux versions.
