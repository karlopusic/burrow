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

struct ArchivedFile: Identifiable, Hashable {
    var id: String { stamp + "/" + path }
    let stamp: String
    let path: String
    let size: Int64
    let modified: Date?
    var date: Date? { Runner.archiveDate(stamp) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status = StatusFile()
    @Published var cfg = AppConfig.load()
    @Published var progress: LiveProgress?
    @Published var boxSpace: (used: Int64, total: Int64)?
    @Published var boxSpaceChecked = false
    @Published var versions: [VersionDir] = []
    @Published var versionFiles: [RemoteFile] = []
    @Published var loadingVersions = false
    @Published var loadingFiles = false
    @Published var archivedFiles: [String: [ArchivedFile]] = [:]
    @Published var archiveIndexLoading = false
    @Published var archiveIndexError: String?
    @Published var toast: String?
    @Published var connection: String?
    @Published var localAccess = true
    @Published var keySetupBusy = false
    @Published var keySetupResult: KeySetup.Outcome?
    @Published var migration: LegacyMigration.State = .none
    @Published var bookmarks: [Bookmark] = []
    private var browsers: [UUID: BrowserModel] = [:]

    private var timer: Timer?
    private var pendingAgentInstall = false
    private var archiveIndexKey: String?

    init() {
        Paths.ensure()
        migration = LegacyMigration.runIfNeeded()
        cfg = AppConfig.load()
        if cfg.isConnectionConfigured { cfg.writeRcloneConfig() }
        loadBookmarks()
        Task.detached { try? RcloneDaemon.shared.startIfNeeded() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DirCache.saveAll() }
            RcloneDaemon.shared.stop()
        }
        warmUp()
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

    /// Starts a fresh instance once this one has quit (used after changing the language). A running backup is a
    /// separate process and is not affected.
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec \"$0\"", Paths.executable]
        try? p.run()
        NSApp.terminate(nil)
    }

    func openLog(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    func openLogsFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.logs)) }
    func openLocalFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: cfg.localPath)) }
    func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    // MARK: bookmarks

    private func loadBookmarks() {
        bookmarks = BookmarkStore.load()
        // First run after the upgrade: turn the backup connection into the first bookmark.
        if bookmarks.isEmpty && cfg.isConnectionConfigured {
            var b = Bookmark()
            b.name = cfg.host.hasSuffix("your-storagebox.de") ? "Storage Box" : cfg.host
            b.host = cfg.host; b.port = cfg.port; b.user = cfg.user; b.keyFile = cfg.keyFile
            bookmarks = [b]
            BookmarkStore.save(bookmarks)
            cfg.use(b); cfg.save()
        }
    }

    /// Opens the SSH connection and loads the last folder of the first few servers right at launch,
    /// so the first click in the browser doesn't wait for the handshake.
    private func warmUp() {
        for b in bookmarks.prefix(5) where b.isComplete {
            let m = browser(for: b)
            Task { await m.connect() }
        }
    }

    func browser(for b: Bookmark) -> BrowserModel {
        if let m = browsers[b.id] { return m }
        let m = BrowserModel(bookmark: b)
        browsers[b.id] = m
        return m
    }

    func saveBookmark(_ b: Bookmark) {
        if let i = bookmarks.firstIndex(where: { $0.id == b.id }) { bookmarks[i] = b } else { bookmarks.append(b) }
        BookmarkStore.save(bookmarks)
        browsers[b.id] = nil                         // reconnect with the new settings
        DirCache.discard(b.id)                       // listings may belong to another server/account now
        if cfg.backupBookmarkID == b.id {
            var c = cfg; c.use(b); saveConfig(c)
        }
    }

    func deleteBookmark(_ b: Bookmark) {
        bookmarks.removeAll { $0.id == b.id }
        BookmarkStore.save(bookmarks)
        Keychain.delete(b.id)
        browsers[b.id] = nil
        DirCache.discard(b.id)
        UserDefaults.standard.removeObject(forKey: "lastPath.\(b.id.uuidString)")
        if cfg.backupBookmarkID == b.id { cfg.backupBookmarkID = nil; cfg.save() }
    }

    func testBookmark(_ b: Bookmark) async -> String { await checkBookmark(b).message }

    func checkBookmark(_ b: Bookmark) async -> KeySetup.Outcome {
        do {
            let fs = try await RcloneDaemon.shared.fsBase(b)
            let r = try await RcloneDaemon.shared.call("operations/list", ["fs": fs, "remote": b.path.hasPrefix("/") ? "" : b.path])
            return .init(ok: true, message: L("Connection works ✓ (%ld items)", (r["list"] as? [Any])?.count ?? 0))
        } catch {
            return .init(ok: false, message: L("Connection failed: %@", error.localizedDescription))
        }
    }

    /// Number of entries in a remote folder (absolute or relative to the login folder); 0 if it doesn't exist yet.
    /// Throws for connection problems.
    func remoteItemCount(_ b: Bookmark, path: String) async throws -> Int {
        let base = try await RcloneDaemon.shared.fsBase(b)
        let absolute = path.hasPrefix("/")
        let remote = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        do {
            let r = try await RcloneDaemon.shared.call("operations/list", ["fs": base + (absolute ? "/" : ""), "remote": remote])
            return (r["list"] as? [Any])?.count ?? 0
        } catch let e as RcloneError where e.message.lowercased().contains("not found") {
            return 0
        }
    }

    // MARK: onboarding

    @Published var showOnboarding = false
    static let onboardingSkippedKey = "onboardingSkipped"

    var shouldOfferOnboarding: Bool {
        needsSetup && bookmarks.isEmpty && !UserDefaults.standard.bool(forKey: Self.onboardingSkippedKey)
    }

    func skipOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingSkippedKey)
        showOnboarding = false
    }

    /// Saves the server from the assistant as a bookmark and makes it the backup destination.
    func completeOnboarding(bookmark b: Bookmark, config: AppConfig) {
        saveBookmark(b)
        var c = config
        c.use(b)
        saveConfig(c)
        UserDefaults.standard.set(true, forKey: Self.onboardingSkippedKey)
    }

    // MARK: remote queries

    /// Archive files are indexed once in the background, then looked up by relative backup path in the browser.
    func ensureArchiveIndex(force: Bool = false) {
        guard cfg.isComplete else { return }
        let remote = cfg.versionsRemote
        let key = remote + "|" + String(status.lastSuccess?.end?.timeIntervalSince1970 ?? 0)
        guard force || archiveIndexKey != key else { return }
        if archiveIndexLoading && archiveIndexKey == key { return }
        archiveIndexKey = key
        archiveIndexLoading = true
        archiveIndexError = nil
        Task.detached {
            let r = rclone(["lsjson", "-R", "--files-only", remote])
            if r.code != 0, lastErrorLine(r.err).localizedCaseInsensitiveContains("not found") {
                await MainActor.run {
                    guard self.archiveIndexKey == key else { return }
                    self.archivedFiles = [:]
                    self.archiveIndexLoading = false
                }
                return
            }
            guard r.code == 0, let data = r.out.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                await MainActor.run {
                    guard self.archiveIndexKey == key else { return }
                    self.archiveIndexError = L("Could not load version history: %@", lastErrorLine(r.err))
                    self.archiveIndexLoading = false
                    self.archiveIndexKey = nil
                }
                return
            }
            var index: [String: [ArchivedFile]] = [:]
            let iso = ISO8601DateFormatter()
            for row in rows {
                guard let full = row["Path"] as? String, let slash = full.firstIndex(of: "/") else { continue }
                let stamp = String(full[..<slash])
                guard Runner.archiveDate(stamp) != nil else { continue }
                let path = String(full[full.index(after: slash)...])
                guard !path.isEmpty else { continue }
                let entry = ArchivedFile(stamp: stamp, path: path,
                                         size: (row["Size"] as? NSNumber)?.int64Value ?? 0,
                                         modified: (row["ModTime"] as? String).flatMap(iso.date(from:)))
                index[path, default: []].append(entry)
            }
            for path in Array(index.keys) { index[path]?.sort { $0.stamp > $1.stamp } }
            let result = index
            await MainActor.run {
                guard self.archiveIndexKey == key else { return }
                self.archivedFiles = result
                self.archiveIndexLoading = false
            }
        }
    }

    /// Browser paths are relative to the login folder, except bookmarks rooted at an absolute path.
    func archiveRelativePath(_ itemPath: String, for bookmark: Bookmark) -> String? {
        guard cfg.isBackupServer(bookmark) else { return nil }
        let root: String
        if !cfg.remotePath.hasPrefix("/") || bookmark.path.hasPrefix("/") {
            root = cfg.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else if bookmark.host.hasSuffix(".your-storagebox.de"), cfg.remotePath.hasPrefix("/home/") {
            root = String(cfg.remotePath.dropFirst("/home/".count))
        } else {
            return nil
        }
        guard itemPath.hasPrefix(root + "/") else { return nil }
        return String(itemPath.dropFirst(root.count + 1))
    }

    func downloadArchived(_ entry: ArchivedFile, to folder: URL) {
        let name = RPath.name(entry.path)
        var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        for t in TransferManager.shared.items where t.isActive || t.state == .paused {
            if let p = t.localDestination, RPath.parent(p) == folder.path { taken.insert(RPath.name(p)) }
        }
        let target = folder.appendingPathComponent(RPath.uniqueName(name, taken: taken))
        let t = Transfer(kind: .download, name: name, server: cfg.host, isDir: false,
                         srcFs: cfg.versionsRemote, srcRemote: entry.id,
                         dstFs: "/", dstRemote: String(target.path.dropFirst()),
                         destLabel: target.path.replacingOccurrences(of: Paths.home, with: "~"), refreshKey: nil)
        TransferManager.shared.enqueue(t)
    }

    func refreshBoxSpace() {
        guard cfg.isConnectionConfigured else { return }
        boxSpaceChecked = false
        boxSpace = nil
        Task.detached {
            let r = rclone(["about", "\(AppInfo.remoteName):", "--json"])
            if r.code == 0, let d = r.out.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let used = (j["used"] as? NSNumber)?.int64Value,
                  let total = (j["total"] as? NSNumber)?.int64Value {
                await MainActor.run { self.boxSpace = (used, total); self.boxSpaceChecked = true }
            } else {
                await MainActor.run { self.boxSpaceChecked = true }
            }
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
                .map { VersionDir(name: $0, date: Runner.archiveDate($0)) }
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
    /// "Today at 21:00", "Tomorrow at 21:00", "3 Oct 2026 at 21:00".
    static let dayTime: DateFormatter = {
        let f = DateFormatter(); f.locale = locale; f.dateStyle = .medium; f.timeStyle = .short
        f.doesRelativeDateFormatting = true; return f
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
    static func remaining(_ seconds: Double) -> String? {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated; f.allowedUnits = [.hour, .minute, .second]; f.maximumUnitCount = 2
        f.includesTimeRemainingPhrase = true
        var cal = Calendar.current; cal.locale = locale; f.calendar = cal
        return f.string(from: seconds)
    }
    static var weekdays: [String] {
        var cal = Calendar.current; cal.locale = locale
        let s = cal.standaloneWeekdaySymbols            // Sunday first
        return Array(s[1...]) + [s[0]]                  // Monday … Sunday
    }
}
