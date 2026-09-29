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
    @Published var versionsError: String?
    @Published var versionFilesError: String?
    @Published var historyEntries: [ArchivedFile] = []
    @Published var historyLoading = false
    @Published var historyError: String?
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
    private var versionFileCache: [String: [RemoteFile]] = [:]
    private var historyCache: [String: [ArchivedFile]] = [:]
    private var versionsRequest = UUID()
    private var filesRequest = UUID()
    private var historyRequest = UUID()
    private var historyTask: Task<Void, Never>?
    private var filesTask: Task<Void, Never>?

    init() {
        Paths.ensure()
        migration = RenameMigration.runIfNeeded()
        if migration == .none { migration = LegacyMigration.runIfNeeded() }
        cfg = AppConfig.load()
        if cfg.isConnectionConfigured { cfg.writeRcloneConfig() }
        loadBookmarks()
        Task.detached { try? RcloneDaemon.shared.startIfNeeded() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DirCache.saveAll() }
            RcloneDaemon.shared.stop()
        }
        warmUp()
        requestNotificationPermission()
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
        let updated = StatusStore.load()
        if status.lastSuccess?.end != updated.lastSuccess?.end { invalidateVersionQueries() }
        status = updated
        progress = status.running.map { LogParser.progress($0.logFile) }
        if pendingAgentInstall && !isRunning { installAgentWhenIdle() }
    }

    /// `launchctl bootout` would kill a running scheduled backup, so the agent is only (re)installed when idle.
    func installAgentWhenIdle() {
        guard migration == .none || migration == .migrated else { return }
        if isRunning { pendingAgentInstall = true; return }
        pendingAgentInstall = false
        let c = cfg
        Task.detached { Agent.install(c) }
    }

    /// Protected folders are checked the way a scheduled run reads them (through launchd), which also makes macOS
    /// ask for permission if needed. Other folders only need to be readable.
    func checkLocalAccess() {
        let path = cfg.localPath
        guard !path.isEmpty else { localAccess = true; return }
        guard cfg.isComplete, AccessCheck.isProtected(path), Install.canSchedule(installLocation) else {
            localAccess = (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
            return
        }
        checkingAccess = true
        Task.detached {
            let ok = AccessCheck.run()
            await MainActor.run {
                self.checkingAccess = false
                // No answer in time (prompt left open) counts as "not yet allowed".
                self.localAccess = ok == true
            }
        }
    }

    // MARK: install location

    @Published var installLocation = Install.current
    @Published var checkingAccess = false

    /// Shown when scheduled backups can't work from where the app runs (DMG, translocated download).
    var shouldOfferMove: Bool { !Install.canSchedule(installLocation) && !Install.isDevelopmentBuild }

    /// Copies the app to Applications and reopens it from there. A running backup is a separate process and continues.
    func moveToApplications() {
        do {
            let target = try Install.moveToApplications()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$0\"", target]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            toast = L("Could not move the app: %@", error.localizedDescription)
        }
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
        if cfg != new { invalidateVersionQueries() }
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
    func openFilesAndFolders() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
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
        needsSetup && bookmarks.isEmpty && (migration == .none || migration == .migrated)
            && !UserDefaults.standard.bool(forKey: Self.onboardingSkippedKey)
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

    private func invalidateVersionQueries() {
        versionsRequest = UUID(); filesRequest = UUID(); historyRequest = UUID()
        filesTask?.cancel(); historyTask?.cancel()
        versions = []; versionFiles = []; historyEntries = []
        loadingVersions = false; loadingFiles = false; historyLoading = false
        versionsError = nil; versionFilesError = nil; historyError = nil
        versionFileCache.removeAll(); historyCache.removeAll()
    }

    // History is fetched for one file when its sheet opens. The old eager recursive scan
    // visited every file in every version and could take minutes on an SFTP server.
    func loadHistory(_ path: String, force: Bool = false) {
        let remote = cfg.versionsRemote
        let key = remote + "|" + String(status.lastSuccess?.end?.timeIntervalSince1970 ?? 0) + "|" + path
        historyTask?.cancel()
        let request = UUID(); historyRequest = request
        if !force, let cached = historyCache[key] {
            historyEntries = cached; historyLoading = false; historyError = nil
            return
        }
        historyEntries = []; historyLoading = true; historyError = nil
        historyTask = Task.detached {
            do {
                let folders = try await Self.fetchVersionDirs(remote)
                var found: [ArchivedFile] = []
                var firstError: String?
                // Limit simultaneous SFTP requests and publish matches after every batch.
                for start in stride(from: 0, to: folders.count, by: 8) {
                    if Task.isCancelled { return }
                    let batch = Array(folders[start..<min(start + 8, folders.count)])
                    await withTaskGroup(of: (ArchivedFile?, String?).self) { group in
                        for folder in batch {
                            group.addTask {
                                do {
                                    let response = try await RcloneDaemon.shared.call("operations/stat", [
                                        "fs": remote, "remote": folder.name + "/" + path])
                                    guard let item = response["item"] as? [String: Any],
                                          item["IsDir"] as? Bool == false else { return (nil, nil) }
                                    let iso = ISO8601DateFormatter()
                                    return (ArchivedFile(stamp: folder.name, path: path,
                                                         size: (item["Size"] as? NSNumber)?.int64Value ?? 0,
                                                         modified: (item["ModTime"] as? String).flatMap(iso.date(from:))), nil)
                                } catch { return (nil, error.localizedDescription) }
                            }
                        }
                        for await (entry, error) in group {
                            if let entry { found.append(entry) }
                            if firstError == nil { firstError = error }
                        }
                    }
                    found.sort { $0.stamp > $1.stamp }
                    let visible = found
                    await MainActor.run {
                        guard self.historyRequest == request else { return }
                        self.historyEntries = visible
                    }
                }
                let result = found
                let error = firstError
                await MainActor.run {
                    guard self.historyRequest == request else { return }
                    self.historyEntries = result
                    self.historyLoading = false
                    self.historyError = error.map { L("Could not load version history: %@", $0) }
                    if error == nil {
                        if self.historyCache.count >= 200 { self.historyCache.removeAll() }
                        self.historyCache[key] = result
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.historyRequest == request else { return }
                    self.historyLoading = false
                    self.historyError = L("Could not load version history: %@", error.localizedDescription)
                }
            }
        }
    }

    func cancelHistory() {
        historyTask?.cancel()
        historyRequest = UUID()
        historyLoading = false
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

    private static func fetchVersionDirs(_ remote: String) async throws -> [VersionDir] {
        let response: [String: Any]
        do {
            response = try await RcloneDaemon.shared.call("operations/list", ["fs": remote, "remote": ""])
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains("not found") { return [] }
            throw error
        }
        return (response["list"] as? [[String: Any]] ?? []).compactMap { item in
            guard item["IsDir"] as? Bool == true, let name = item["Name"] as? String,
                  let date = Runner.archiveDate(name) else { return nil }
            return VersionDir(name: name, date: date)
        }.sorted { $0.name > $1.name }
    }

    func loadVersions() {
        let request = UUID(); versionsRequest = request
        loadingVersions = true; versionsError = nil
        let remote = cfg.versionsRemote
        Task {
            do {
                let list = try await Self.fetchVersionDirs(remote)
                guard versionsRequest == request else { return }
                versions = list; loadingVersions = false
            } catch {
                guard versionsRequest == request else { return }
                versionsError = L("Could not load version history: %@", error.localizedDescription)
                loadingVersions = false
            }
        }
    }

    func loadFiles(_ v: VersionDir) {
        filesTask?.cancel()
        let request = UUID(); filesRequest = request
        let remote = "\(cfg.versionsRemote)/\(v.name)"
        versionFilesError = nil
        if let cached = versionFileCache[remote] {
            versionFiles = cached; loadingFiles = false
            return
        }
        loadingFiles = true; versionFiles = []
        filesTask = Task {
            do {
                var files: [RemoteFile] = []
                try await withThrowingTaskGroup(of: [[String: Any]].self) { group in
                    var queue = [""]
                    var active = 0
                    var listed = 0
                    while !queue.isEmpty || active > 0 {
                        try Task.checkCancellation()
                        while active < 8 && !queue.isEmpty {
                            let dir = queue.removeFirst()
                            group.addTask {
                                let response = try await RcloneDaemon.shared.call("operations/list", [
                                    "fs": remote, "remote": dir])
                                return response["list"] as? [[String: Any]] ?? []
                            }
                            active += 1
                        }
                        guard let rows = try await group.next() else { break }
                        active -= 1; listed += 1
                        for item in rows {
                            guard let path = item["Path"] as? String else { continue }
                            if item["IsDir"] as? Bool == true {
                                queue.append(path)
                            } else {
                                let modified = String((item["ModTime"] as? String ?? "").prefix(16))
                                    .replacingOccurrences(of: "T", with: " ")
                                files.append(RemoteFile(path: path,
                                                        size: (item["Size"] as? NSNumber)?.int64Value ?? 0,
                                                        modTime: modified))
                            }
                        }
                        if filesRequest == request && (listed == 1 || listed % 8 == 0) {
                            versionFiles = files.sorted { $0.path < $1.path }
                        }
                    }
                }
                guard filesRequest == request else { return }
                files.sort { $0.path < $1.path }
                versionFiles = files
                if versionFileCache.count >= 30 { versionFileCache.removeAll() }
                versionFileCache[remote] = files
                loadingFiles = false
            } catch {
                guard filesRequest == request else { return }
                if !(error is CancellationError) {
                    versionFilesError = L("Could not load version history: %@", error.localizedDescription)
                }
                loadingFiles = false
            }
        }
    }

    /// Restores into ~/Downloads/Burrow Restore/<version>/… – never into the live local folder.
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
