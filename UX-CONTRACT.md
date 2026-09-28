# Burrow interaction contract

CONTRIBUTING.md defines the data-safety rules. This file records where visible behavior is owned.

| Capability | Canonical owner | Behavior |
|---|---|---|
| File selection and context menu | `BrowserView` native `Table` and grid | A right-click acts on the selection when included, or the clicked file. |
| Downloads | `BrowserView` → `BrowserModel.download` → `TransferManager` | Download asks for a folder by default; existing and queued names are reserved; progress and failures appear in Transfers. |
| Archived file history | `AppModel.ensureArchiveIndex` and `VersionHistorySheet` | Only files under the configured backup show a marker. Preview/open use a temporary copy. Download asks for a destination. |
| Backup setup | `OnboardingView` and `SettingsView` → `AppConfig` | A dedicated remote folder and separate versions folder are required. `Runner` checks the same invariant before every run. |
| Remote removal | `BrowserModel.trash` | Normal removal goes to server trash. Permanent removal is confined to trash and confirmed. |
| Server identity | `HostVerifier` and `HostKeys` | The user confirms the fingerprint before first use or a changed host key is trusted. |
| Updates | `UpdateController` and Sparkle | Automatic checks and a manual check use a signed appcast. Publishing requires a notarized Developer ID build and signed update archive. |

Errors stay visible until resolved or dismissed. Slow archive scans leave folder navigation responsive. Every icon-only action needs a localized tooltip or accessible label. The UI supports English, Croatian and German.
