import Foundation
import AppKit
import SwiftUI

struct VersionDir: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let date: Date?
}

struct RemoteFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let size: Int64
    let modTime: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status = StatusFile()
    @Published var cfg = AppConfig.load()
    @Published var progress: LiveProgress?
    @Published var boxSpace: (used: Int64, total: Int64)?
    @Published var versions: [VersionDir] = []
    @Published var versionFiles: [RemoteFile] = []
    @Published var loadingVersions = false
    @Published var loadingFiles = false
    @Published var toast: String?
    @Published var connection: String?
    @Published var localAccess = true
    @Published var keySetupBusy = false
    @Published var keySetupResult: KeySetup.Outcome?
    @Published var migration: LegacyMigration.State = .none

    private var timer: Timer?
    private var pendingAgentInstall = false

    init() {
        Paths.ensure()
        migration = LegacyMigration.runIfNeeded()
        cfg = AppConfig.load()
        if cfg.isConnectionConfigured { cfg.writeRcloneConfig() }
        reload()
        installAgentWhenIdle()
        checkLocalAccess()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        refreshBoxSpace()
    }

    var isRunning: Bool { status.running != nil }
    var needsSetup: Bool { !cfg.isComplete }

    func reload() {
        status = StatusStore.load()
        progress = status.running.map { LogParser.progress($0.logFile) }
        if pendingAgentInstall && !isRunning { installAgentWhenIdle() }
    }

    /// `launchctl bootout` would kill a running scheduled backup, so the agent is only (re)installed when idle.
    func installAgentWhenIdle() {
        if isRunning { pendingAgentInstall = true; return }
        pendingAgentInstall = false
        let c = cfg
        Task.detached { Agent.install(c) }
    }

    func checkLocalAccess() {
        guard !cfg.localPath.isEmpty else { localAccess = true; return }
        localAccess = (try? FileManager.default.contentsOfDirectory(atPath: cfg.localPath)) != nil
    }

    // MARK: actions

    private func spawnSelf(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.executable)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { toast = L("Could not start: %@", error.localizedDescription) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.reload() }
    }

    func startBackup(force: Bool = false) {
        guard !isRunning, !needsSetup else { return }
        if force { FileManager.default.createFile(atPath: Paths.forceFlag, contents: nil) }
        spawnSelf(["--run", "--trigger=manual"])
    }

    func startDryRun() {
        guard !isRunning, !needsSetup else { return }
        spawnSelf(["--dry-run", "--trigger=manual"])
    }

    func stop() {
        guard let r = status.running else { return }
        FileManager.default.createFile(atPath: Paths.stopFlag, contents: nil)
        if r.childPid > 0 { kill(r.childPid, SIGTERM) }
    }

    func saveConfig(_ new: AppConfig) {
        cfg = new
        cfg.save()
        installAgentWhenIdle()
        checkLocalAccess()
        refreshBoxSpace()
        toast = L("Settings saved.")
    }

    func installKey(host: String, port: Int, user: String, password: String, keyFile: String) {
        keySetupBusy = true
        keySetupResult = nil
        Task.detached {
            let r = KeySetup.run(host: host, port: port, user: user, password: password, keyFile: keyFile)
            await MainActor.run {
                self.keySetupBusy = false
                self.keySetupResult = r
            }
        }
    }

    func openLog(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    func openLogsFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.logs)) }
    func openLocalFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: cfg.localPath)) }
    func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    // MARK: remote queries

    func refreshBoxSpace() {
        guard cfg.isConnectionConfigured else { return }
        Task.detached {
            let r = rclone(["about", "\(AppInfo.remoteName):", "--json"])
            guard r.code == 0, let d = r.out.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let used = (j["used"] as? NSNumber)?.int64Value,
                  let total = (j["total"] as? NSNumber)?.int64Value else { return }
            await MainActor.run { self.boxSpace = (used, total) }
        }
    }

    func testConnection(_ c: AppConfig) {
        connection = L("Checking…")
        c.writeRcloneConfig()
        Task.detached {
            let r = rclone(["lsf", "--max-depth", "1", "\(AppInfo.remoteName):"])
            let msg = r.code == 0 ? L("Connection works ✓") : L("Connection failed: %@", lastErrorLine(r.err))
            await MainActor.run { self.connection = msg }
        }
    }

    func loadVersions() {
        loadingVersions = true
        let remote = cfg.versionsRemote
        Task.detached {
            let r = rclone(["lsf", "--dirs-only", remote])
            let list = r.out.split(separator: "\n")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
                .map { VersionDir(name: $0, date: Runner.stampFormatter.date(from: $0)) }
                .sorted { $0.name > $1.name }
            await MainActor.run { self.versions = list; self.loadingVersions = false }
        }
    }

    func loadFiles(_ v: VersionDir) {
        loadingFiles = true
        versionFiles = []
        let remote = "\(cfg.versionsRemote)/\(v.name)"
        Task.detached {
            let r = rclone(["lsjson", "-R", "--files-only", remote])
            var files: [RemoteFile] = []
            if let d = r.out.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                files = arr.compactMap { o in
                    guard let p = o["Path"] as? String else { return nil }
                    return RemoteFile(path: p, size: (o["Size"] as? NSNumber)?.int64Value ?? 0,
                                      modTime: String((o["ModTime"] as? String ?? "").prefix(16)).replacingOccurrences(of: "T", with: " "))
                }.sorted { $0.path < $1.path }
            }
            let result = files
            await MainActor.run { self.versionFiles = result; self.loadingFiles = false }
        }
    }

    /// Restores into ~/Downloads/StorageBox Sync Restore/<version>/… – never into the live local folder.
    func restore(version: VersionDir, file: RemoteFile?) {
        let base = "\(cfg.versionsRemote)/\(version.name)"
        let destRoot = "\(Paths.restoreRoot)/\(version.name)"
        toast = L("Restoring…")
        Task.detached {
            let r: ShellResult
            let reveal: String
            if let f = file {
                reveal = destRoot + "/" + f.path
                r = rclone(["copyto", "\(base)/\(f.path)", reveal, "--ignore-existing"])
            } else {
                reveal = destRoot
                r = rclone(["copy", base, destRoot, "--ignore-existing"])
            }
            await MainActor.run {
                if r.code == 0 {
                    self.toast = L("Restored to Downloads/%@", "\(AppInfo.name) Restore/\(version.name)")
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: reveal)])
                } else {
                    self.toast = L("Restore failed: %@", lastErrorLine(r.err))
                }
            }
        }
    }
}

// MARK: - formatting

enum Fmt {
    /// Follows the language the app UI is actually shown in, not just the region.
    static var locale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }

    static let date: DateFormatter = {
        let f = DateFormatter(); f.locale = locale; f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.locale = locale; f.unitsStyle = .full; return f
    }()
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .binary) }
    static func duration(_ a: Date, _ b: Date?) -> String {
        guard let b else { return "—" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated; f.allowedUnits = [.hour, .minute, .second]; f.maximumUnitCount = 2
        var cal = Calendar.current; cal.locale = locale; f.calendar = cal
        return f.string(from: b.timeIntervalSince(a)) ?? "—"
    }
    static var weekdays: [String] {
        var cal = Calendar.current; cal.locale = locale
        let s = cal.standaloneWeekdaySymbols            // Sunday first
        return Array(s[1...]) + [s[0]]                  // Monday … Sunday
    }
}
