import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RemoteItem: Identifiable, Hashable, Codable {
    var id: String { path }
    let path: String          // relative to the browser's fs root
    let name: String
    let size: Int64
    let modified: Date?
    let isDir: Bool

    private var ext: String { isDir ? "/" : (name as NSString).pathExtension.lowercased() }

    // Icons and kind names are looked up once per extension – large folders render without hitting LaunchServices per row.
    @MainActor private static var icons: [String: NSImage] = [:]
    @MainActor private static var kinds: [String: String] = [:]

    @MainActor var kind: String {
        if let k = Self.kinds[ext] { return k }
        let k = isDir ? L("Folder") : (UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased())
        Self.kinds[ext] = k
        return k
    }
    @MainActor var icon: NSImage {
        if let i = Self.icons[ext] { return i }
        let i = isDir ? NSWorkspace.shared.icon(for: .folder)
                      : NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        Self.icons[ext] = i
        return i
    }
}

enum ConflictChoice { case replace, keepBoth, skip }

/// State and operations for one bookmark's browser window pane.
@MainActor
final class BrowserModel: ObservableObject {
    let bookmark: Bookmark

    @Published var cwd: String
    @Published var items: [RemoteItem] = []
    @Published var loading = false
    @Published var error: String?
    @Published var showHidden = false
    @Published var searchText = ""
    @Published var searchResults: [RemoteItem]?
    @Published var searching = false
    @Published var busy: String?
    @Published var quickLookURL: URL?
    @Published var clipboard: (items: [RemoteItem], cut: Bool)?
    /// Operations still preparing work (conflict checks, moving replaced items to trash) before they queue transfers.
    @Published var pendingOps = 0
    /// A cached listing is shown while the fresh one loads.
    @Published var refreshing = false

    private let cache: DirCache
    private var prefetchTask: Task<Void, Never>?
    private var lastPathKey: String { "lastPath.\(bookmark.id.uuidString)" }

    private var back: [String] = []
    private var forward: [String] = []
    private var fsRoot = ""
    private var observer: NSObjectProtocol?

    /// Absolute bookmark paths browse from "/", relative ones from the login folder.
    private var absolute: Bool { bookmark.path.hasPrefix("/") }

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        self.cache = DirCache.forBookmark(bookmark.id)
        let start = bookmark.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.cwd = UserDefaults.standard.string(forKey: "lastPath.\(bookmark.id.uuidString)") ?? start
        if let cached = cache.get(cwd) { items = cached.items }   // instant first paint, even before connecting
        observer = NotificationCenter.default.addObserver(forName: .remoteChanged, object: nil, queue: .main) { [weak self] n in
            guard let key = n.object as? String else { return }
            Task { @MainActor in
                guard let self, !self.fsRoot.isEmpty, key.hasPrefix(self.fsRoot + "|") else { return }
                let dir = String(key.dropFirst(self.fsRoot.count + 1))
                if dir == self.cwd { await self.reload() } else { self.cache.markStale(dir) }
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    // MARK: derived

    var displayPath: String { (absolute ? "/" : "~/") + cwd }
    var breadcrumbs: [(name: String, path: String)] {
        var out: [(String, String)] = [(absolute ? "/" : bookmark.displayName, "")]
        var acc = ""
        for part in cwd.split(separator: "/") {
            acc = RPath.join(acc, String(part))
            out.append((String(part), acc))
        }
        return out
    }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var canGoUp: Bool { !cwd.isEmpty }
    var trashPath: String {
        absolute ? RPath.join(bookmark.path, bookmark.trashFolder) : bookmark.trashFolder
    }
    var inTrash: Bool { cwd == trashPath || cwd.hasPrefix(trashPath + "/") }

    var visibleItems: [RemoteItem] {
        let base = searchResults ?? items
        return showHidden ? base : base.filter { !$0.name.hasPrefix(".") }
    }

    func refreshKey(_ dir: String) -> String { fsRoot + "|" + dir }
    func fs(_ path: String) -> String { fsRoot + path }

    // MARK: navigation

    func connect() async {
        guard fsRoot.isEmpty else { return }
        do {
            fsRoot = try await RcloneDaemon.shared.fsBase(bookmark) + (absolute ? "/" : "")
            show(cwd)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func open(_ path: String) {
        guard path != cwd else { return }
        back.append(cwd); forward.removeAll()
        navigate(to: path)
    }

    func goBack() { guard let p = back.popLast() else { return }; forward.append(cwd); navigate(to: p) }
    func goForward() { guard let p = forward.popLast() else { return }; back.append(cwd); navigate(to: p) }

    private func navigate(to path: String) {
        cwd = path
        clearSearch()
        UserDefaults.standard.set(path, forKey: lastPathKey)
        show(path)
    }

    /// Cached listing → shown immediately and refreshed in the background. Unknown folder → spinner.
    private func show(_ dir: String) {
        error = nil
        if let cached = cache.get(dir) {
            items = cached.items
            loading = false
            refreshing = true
        } else {
            items = []
            loading = true
        }
        Task { await fetchCurrent(dir, keepError: false) }
    }
    func goUp() { if canGoUp { open(RPath.parent(cwd)) } }
    func openTrash() { open(trashPath) }

    /// Fresh listing of the current folder. `keepError`: a refresh after an operation must not hide its error.
    func reload(keepError: Bool = false) async {
        guard !fsRoot.isEmpty else { await connect(); return }
        if items.isEmpty { loading = true } else { refreshing = true }
        await fetchCurrent(cwd, keepError: keepError)
    }

    private func fetchCurrent(_ dir: String, keepError: Bool) async {
        guard !fsRoot.isEmpty else { return }
        if !keepError { error = nil }
        do {
            let fresh = try await list(dir)
            guard dir == cwd else { return }          // user navigated on meanwhile; the cache got it anyway
            if fresh != items { items = fresh }
            if inTrash { await prepareTrashFolder() }
            prefetchChildren(of: fresh)
        } catch {
            guard dir == cwd else { return }
            if cache.get(dir) == nil { items = [] }
            self.error = (error as? RcloneError)?.message ?? error.localizedDescription
        }
        if dir == cwd { loading = false; refreshing = false }
    }

    /// Loads the visible subfolders in the background (3 at a time, up to 40) so opening them is instant.
    private func prefetchChildren(of list: [RemoteItem]) {
        prefetchTask?.cancel()
        let targets = list.filter { $0.isDir && (showHidden || !$0.name.hasPrefix(".")) }
            .map(\.path)
            .filter { (cache.age($0) ?? .infinity) > 120 }
            .prefix(40)
        guard !targets.isEmpty else { return }
        let queue = Array(targets)
        prefetchTask = Task { [weak self] in
            var next = 0
            await withTaskGroup(of: Void.self) { group in
                func add() {
                    guard next < queue.count else { return }
                    let dir = queue[next]; next += 1
                    group.addTask { _ = try? await self?.list(dir) }
                }
                for _ in 0..<3 { add() }
                for await _ in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    add()
                }
            }
        }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    private func parse(_ list: [[String: Any]], base: String) -> [RemoteItem] {
        list.compactMap { e in
            guard let p = e["Path"] as? String, let n = e["Name"] as? String else { return nil }
            let t = e["ModTime"] as? String ?? ""
            let trimmed = t.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
            // operations/list returns paths relative to the fs root (already including `base`)
            let full = base.isEmpty || p == base || p.hasPrefix(base + "/") ? p : RPath.join(base, p)
            return RemoteItem(path: full, name: n,
                              size: (e["Size"] as? NSNumber)?.int64Value ?? 0,
                              modified: Self.isoFrac.date(from: trimmed) ?? Self.iso.date(from: t),
                              isDir: e["IsDir"] as? Bool ?? false)
        }
        .sorted { a, b in a.isDir != b.isDir ? a.isDir : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    /// Always asks the server; every result also refreshes the cache.
    func list(_ dir: String) async throws -> [RemoteItem] {
        let r = try await RcloneDaemon.shared.call("operations/list", ["fs": fsRoot, "remote": dir])
        let items = parse(r["list"] as? [[String: Any]] ?? [], base: dir)
        cache.put(dir, items)
        return items
    }

    // MARK: search

    func search() {
        let term = searchText.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { clearSearch(); return }
        searching = true
        let escaped = term.replacingOccurrences(of: #"([\\\[\]{}*?])"#, with: #"\\$1"#, options: .regularExpression)
        let dir = cwd
        Task {
            defer { searching = false }
            do {
                let r = try await RcloneDaemon.shared.call("operations/list", [
                    "fs": fsRoot, "remote": dir, "opt": ["recurse": true],
                    "_filter": ["IncludeRule": ["*\(escaped)*", "*\(escaped)*/**"], "IgnoreCase": true],
                ])
                let found = parse(r["list"] as? [[String: Any]] ?? [], base: dir)
                    .filter { $0.name.localizedCaseInsensitiveContains(term) }
                searchResults = found
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func clearSearch() { searchText = ""; searchResults = nil }

    // MARK: file operations

    private func run(_ label: String, _ work: @escaping () async throws -> Void) {
        busy = label
        Task {
            do { try await work() } catch {
                self.error = (error as? RcloneError)?.message ?? error.localizedDescription
            }
            busy = nil
            await reload(keepError: true)
        }
    }

    /// Server-side move of a file or folder. Refuses to overwrite anything.
    private func move(_ item: RemoteItem, to dest: String) async throws {
        // SFTP rename needs the target's parent folder to exist (e.g. a new dated trash folder)
        let parent = RPath.parent(dest)
        if !parent.isEmpty { _ = try await RcloneDaemon.shared.call("operations/mkdir", ["fs": fsRoot, "remote": parent]) }
        defer {
            cache.markStale(RPath.parent(item.path)); cache.markStale(parent)
            if item.isDir { cache.removeTree(item.path) }
        }
        if item.isDir {
            _ = try await RcloneDaemon.shared.call("sync/move", ["srcFs": fs(item.path), "dstFs": fs(dest), "deleteEmptySrcDirs": true])
            // sync/move leaves the (now empty) source folder itself behind
            _ = try? await RcloneDaemon.shared.call("operations/rmdirs", ["fs": fsRoot, "remote": item.path, "leaveRoot": false])
        } else {
            _ = try await RcloneDaemon.shared.call("operations/movefile",
                ["srcFs": fsRoot, "srcRemote": item.path, "dstFs": fsRoot, "dstRemote": dest])
        }
    }

    /// Conflict checks never trust the cache: a stale listing could let a move overwrite a file.
    private func names(in dir: String) async throws -> Set<String> {
        Set(try await list(dir).map(\.name))
    }

    func newFolder(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("/") else { return }
        run(L("Creating folder…")) { [self] in
            guard !(try await names(in: cwd)).contains(n) else { throw RcloneError(message: L("“%@” already exists.", n)) }
            _ = try await RcloneDaemon.shared.call("operations/mkdir", ["fs": fsRoot, "remote": RPath.join(cwd, n)])
            cache.markStale(cwd)
        }
    }

    func rename(_ item: RemoteItem, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("/"), n != item.name else { return }
        run(L("Renaming…")) { [self] in
            let parent = RPath.parent(item.path)
            guard !(try await names(in: parent)).contains(n) else { throw RcloneError(message: L("“%@” already exists.", n)) }
            try await move(item, to: RPath.join(parent, n))
        }
    }

    // MARK: trash
    //
    // Layout: <trash>/<yyyy-MM-dd_HHmmss>/<item name>, plus <trash>/<stamp>/.origins.json = {name: original path}.
    // Deleted items appear directly in their dated folder (like the Finder trash) and "Put Back" knows where they came from.

    private var origins: [String: [String: String]] = [:]   // stamp folder path → name → original path

    static let trashStamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HHmmss"; return f
    }()

    /// Moves items into a new dated trash folder. Used by "Move to Trash" and by "Replace" during uploads.
    func trash(_ selection: [RemoteItem]) async throws {
        let stampDir = RPath.join(trashPath, Self.trashStamp.string(from: Date()))
        var map = try await loadOrigins(stampDir)
        var taken = Set(map.keys)
        for item in selection {
            let name = RPath.uniqueName(item.name, taken: taken)
            taken.insert(name)
            try await move(item, to: RPath.join(stampDir, name))
            map[name] = item.path
            try await writeOrigins(map, to: stampDir)   // after every item, so a failure midway loses nothing
        }
    }

    func moveToTrash(_ selection: [RemoteItem]) {
        run(L("Moving to trash…")) { [self] in try await trash(selection) }
    }

    private func loadOrigins(_ stampDir: String) async throws -> [String: String] {
        if let m = origins[stampDir] { return m }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try? await RcloneDaemon.shared.call("operations/copyfile", [
            "srcFs": fsRoot, "srcRemote": RPath.join(stampDir, ".origins.json"),
            "dstFs": "/", "dstRemote": String(tmp.path.dropFirst())])
        let map = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: tmp))) ?? [:]
        origins[stampDir] = map
        return map
    }

    private func writeOrigins(_ map: [String: String], to stampDir: String) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try JSONEncoder().encode(map).write(to: tmp)
        _ = try await RcloneDaemon.shared.call("operations/copyfile", [
            "srcFs": "/", "srcRemote": String(tmp.path.dropFirst()),
            "dstFs": fsRoot, "dstRemote": RPath.join(stampDir, ".origins.json")])
        origins[stampDir] = map
        cache.markStale(stampDir)
    }

    private func isStampFolder(_ item: RemoteItem) -> Bool { item.isDir && RPath.parent(item.path) == trashPath }

    /// Original location of an item that sits directly in a dated trash folder (nil if unknown or not in the trash).
    func originalPath(_ item: RemoteItem) -> String? {
        let stampDir = RPath.parent(item.path)
        guard RPath.parent(stampDir) == trashPath else { return nil }
        return origins[stampDir]?[item.name]
    }

    func canPutBack(_ item: RemoteItem) -> Bool { isStampFolder(item) || originalPath(item) != nil }

    /// Called when a dated trash folder is opened, so the context menu knows what can be put back.
    func prepareTrashFolder() async {
        guard RPath.parent(cwd) == trashPath else { return }
        _ = try? await loadOrigins(cwd)
        objectWillChange.send()
    }

    func putBack(_ selection: [RemoteItem]) {
        run(L("Restoring…")) { [self] in
            // a whole dated folder = every item in it
            var todo: [RemoteItem] = []
            for item in selection {
                if isStampFolder(item) { todo += try await list(item.path).filter { $0.name != ".origins.json" } }
                else { todo.append(item) }
            }
            for item in todo {
                let stampDir = RPath.parent(item.path)
                var map = try await loadOrigins(stampDir)
                guard let orig = map[item.name] else { continue }
                let parent = RPath.parent(orig)
                let taken = (try? await names(in: parent)) ?? []
                try await move(item, to: RPath.join(parent, RPath.uniqueName(RPath.name(orig), taken: taken)))
                map[item.name] = nil
                if map.isEmpty {
                    _ = try? await RcloneDaemon.shared.call("operations/purge", ["fs": fsRoot, "remote": stampDir])
                    origins[stampDir] = nil
                    cache.removeTree(stampDir); cache.markStale(trashPath)
                } else {
                    try await writeOrigins(map, to: stampDir)
                }
            }
        }
    }

    /// Only ever called for items already in the trash, after explicit confirmation.
    func deletePermanently(_ selection: [RemoteItem]) {
        run(L("Deleting…")) { [self] in
            for item in selection where item.path.hasPrefix(trashPath + "/") {
                try await removeForGood(item)
            }
        }
    }

    func emptyTrash() {
        run(L("Emptying trash…")) { [self] in
            for item in try await list(trashPath) {
                try await removeForGood(item)
            }
        }
    }

    private func removeForGood(_ item: RemoteItem) async throws {
        if item.isDir {
            _ = try await RcloneDaemon.shared.call("operations/purge", ["fs": fsRoot, "remote": item.path])
            cache.removeTree(item.path)
        } else {
            _ = try await RcloneDaemon.shared.call("operations/deletefile", ["fs": fsRoot, "remote": item.path])
        }
        cache.markStale(RPath.parent(item.path))
    }

    func copy(_ selection: [RemoteItem]) { clipboard = (selection, false) }
    func cut(_ selection: [RemoteItem]) { clipboard = (selection, true) }

    func paste() {
        guard let clip = clipboard else { return }
        let dest = cwd
        if clip.cut {
            clipboard = nil
            run(L("Moving…")) { [self] in
                var taken = try await names(in: dest)
                for item in clip.items where RPath.parent(item.path) != dest {
                    guard !(dest == item.path || dest.hasPrefix(item.path + "/")) else {
                        throw RcloneError(message: L("Can't move a folder into itself."))
                    }
                    let n = RPath.uniqueName(item.name, taken: taken)
                    taken.insert(n)
                    try await move(item, to: RPath.join(dest, n))
                }
            }
        } else {
            pendingOps += 1
            Task {
                defer { pendingOps -= 1 }
                var taken = (try? await names(in: dest)) ?? []
                for item in clip.items {
                    let n = RPath.uniqueName(item.name, taken: taken)
                    taken.insert(n)
                    enqueueRemoteCopy(item, to: RPath.join(dest, n))
                }
            }
        }
    }

    func duplicate(_ selection: [RemoteItem]) {
        pendingOps += 1
        Task {
            defer { pendingOps -= 1 }
            for item in selection {
                let parent = RPath.parent(item.path)
                let taken = (try? await names(in: parent)) ?? []
                enqueueRemoteCopy(item, to: RPath.join(parent, RPath.uniqueName(item.name, taken: taken)))
            }
        }
    }

    private func enqueueRemoteCopy(_ item: RemoteItem, to dest: String) {
        let t = Transfer(kind: .copy, name: item.name, server: bookmark.displayName, isDir: item.isDir,
                         srcFs: item.isDir ? fs(item.path) : fsRoot, srcRemote: item.isDir ? nil : item.path,
                         dstFs: item.isDir ? fs(dest) : fsRoot, dstRemote: item.isDir ? nil : dest,
                         destLabel: "\(bookmark.displayName): \(dest)", refreshKey: refreshKey(RPath.parent(dest)))
        TransferManager.shared.enqueue(t)
    }

    // MARK: transfers

    func download(_ selection: [RemoteItem], to folder: URL) {
        let fm = FileManager.default
        var taken = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        for transfer in TransferManager.shared.items where transfer.isActive || transfer.state == .paused {
            guard let destination = transfer.localDestination,
                  RPath.parent(destination) == folder.path else { continue }
            taken.insert(URL(fileURLWithPath: destination).lastPathComponent)
        }
        for item in selection {
            let name = RPath.uniqueName(item.name, taken: taken)
            taken.insert(name)
            let target = folder.appendingPathComponent(name)
            let local = String(target.path.dropFirst())  // relative to local fs root "/"
            let t = Transfer(kind: .download, name: item.name, server: bookmark.displayName, isDir: item.isDir,
                             srcFs: item.isDir ? fs(item.path) : fsRoot, srcRemote: item.isDir ? nil : item.path,
                             dstFs: item.isDir ? target.path : "/", dstRemote: item.isDir ? nil : local,
                             destLabel: target.path.replacingOccurrences(of: Paths.home, with: "~"), refreshKey: nil)
            TransferManager.shared.enqueue(t)
        }
    }

    /// Uploads local files/folders into `dir`. Existing names are resolved by `choose`; "Replace" moves the old copy to the trash first.
    func upload(_ urls: [URL], into dir: String? = nil, choose: @escaping (String) async -> ConflictChoice) {
        let dest = dir ?? cwd
        pendingOps += 1
        Task {
            defer { pendingOps -= 1 }
            var taken = (try? await names(in: dest)) ?? []
            for url in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                var name = url.lastPathComponent
                if taken.contains(name) {
                    switch await choose(name) {
                    case .skip: continue
                    case .keepBoth: name = RPath.uniqueName(name, taken: taken)
                    case .replace:
                        let existing = ((try? await list(dest)) ?? []).first { $0.name == name }
                        if let existing {
                            do {
                                try await trash([existing])
                            } catch {
                                self.error = error.localizedDescription
                                continue
                            }
                        }
                    }
                }
                taken.insert(name)
                let remote = RPath.join(dest, name)
                let t = Transfer(kind: .upload, name: name, server: bookmark.displayName, isDir: isDir.boolValue,
                                 srcFs: isDir.boolValue ? url.path : "/", srcRemote: isDir.boolValue ? nil : String(url.path.dropFirst()),
                                 dstFs: isDir.boolValue ? fs(remote) : fsRoot, dstRemote: isDir.boolValue ? nil : remote,
                                 destLabel: "\(bookmark.displayName): \(remote)", refreshKey: refreshKey(dest))
                TransferManager.shared.enqueue(t)
            }
            await reload(keepError: true)
        }
    }

    // MARK: preview & info

    static let previewCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppInfo.name + "/Preview")

    func quickLook(_ item: RemoteItem) {
        guard !item.isDir else { open(item.path); return }
        let dir = Self.previewCache.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(item.name)
        busy = L("Loading preview…")
        Task {
            defer { busy = nil }
            do {
                _ = try await RcloneDaemon.shared.call("operations/copyfile",
                    ["srcFs": fsRoot, "srcRemote": item.path, "dstFs": "/", "dstRemote": String(target.path.dropFirst())])
                quickLookURL = target
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func folderSize(_ item: RemoteItem) async -> (count: Int, bytes: Int64)? {
        guard let r = try? await RcloneDaemon.shared.call("operations/size", ["fs": fs(item.path)]) else { return nil }
        return ((r["count"] as? NSNumber)?.intValue ?? 0, (r["bytes"] as? NSNumber)?.int64Value ?? 0)
    }

    func copyPath(_ item: RemoteItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((absolute ? "/" : "") + item.path, forType: .string)
    }
}
