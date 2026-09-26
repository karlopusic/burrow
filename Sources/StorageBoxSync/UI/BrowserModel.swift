import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RemoteItem: Identifiable, Hashable {
    var id: String { path }
    let path: String          // relative to the browser's fs root
    let name: String
    let size: Int64
    let modified: Date?
    let isDir: Bool

    var kind: String {
        if isDir { return L("Folder") }
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
    }
    var icon: NSImage {
        if isDir { return NSWorkspace.shared.icon(for: .folder) }
        let t = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: t)
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

    private var back: [String] = []
    private var forward: [String] = []
    private var fsRoot = ""
    private var observer: NSObjectProtocol?

    /// Absolute bookmark paths browse from "/", relative ones from the login folder.
    private var absolute: Bool { bookmark.path.hasPrefix("/") }

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        self.cwd = bookmark.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        observer = NotificationCenter.default.addObserver(forName: .remoteChanged, object: nil, queue: .main) { [weak self] n in
            guard let key = n.object as? String else { return }
            Task { @MainActor in
                guard let self, !self.fsRoot.isEmpty else { return }
                if key == self.refreshKey(self.cwd) { await self.reload() }
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
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func open(_ path: String) {
        guard path != cwd else { return }
        back.append(cwd); forward.removeAll()
        cwd = path
        clearSearch()
        Task { await reload() }
    }

    func goBack() { guard let p = back.popLast() else { return }; forward.append(cwd); cwd = p; clearSearch(); Task { await reload() } }
    func goForward() { guard let p = forward.popLast() else { return }; back.append(cwd); cwd = p; clearSearch(); Task { await reload() } }
    func goUp() { if canGoUp { open(RPath.parent(cwd)) } }
    func openTrash() { open(trashPath) }

    /// `keepError`: refresh after an operation must not hide the error that operation just reported.
    func reload(keepError: Bool = false) async {
        guard !fsRoot.isEmpty else { await connect(); return }
        loading = true
        if !keepError { error = nil }
        defer { loading = false }
        do {
            items = try await list(cwd)
            if inTrash { await prepareTrashFolder() }
        } catch {
            items = []
            self.error = (error as? RcloneError)?.message ?? error.localizedDescription
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

    func list(_ dir: String) async throws -> [RemoteItem] {
        let r = try await RcloneDaemon.shared.call("operations/list", ["fs": fsRoot, "remote": dir])
        return parse(r["list"] as? [[String: Any]] ?? [], base: dir)
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
        if item.isDir {
            _ = try await RcloneDaemon.shared.call("sync/move", ["srcFs": fs(item.path), "dstFs": fs(dest), "deleteEmptySrcDirs": true])
            // sync/move leaves the (now empty) source folder itself behind
            _ = try? await RcloneDaemon.shared.call("operations/rmdirs", ["fs": fsRoot, "remote": item.path, "leaveRoot": false])
        } else {
            _ = try await RcloneDaemon.shared.call("operations/movefile",
                ["srcFs": fsRoot, "srcRemote": item.path, "dstFs": fsRoot, "dstRemote": dest])
        }
    }

    private func names(in dir: String) async throws -> Set<String> {
        dir == cwd ? Set(items.map(\.name)) : Set(try await list(dir).map(\.name))
    }

    func newFolder(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("/") else { return }
        run(L("Creating folder…")) { [self] in
            guard !(try await names(in: cwd)).contains(n) else { throw RcloneError(message: L("“%@” already exists.", n)) }
            _ = try await RcloneDaemon.shared.call("operations/mkdir", ["fs": fsRoot, "remote": RPath.join(cwd, n)])
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
                if item.isDir {
                    _ = try await RcloneDaemon.shared.call("operations/purge", ["fs": fsRoot, "remote": item.path])
                } else {
                    _ = try await RcloneDaemon.shared.call("operations/deletefile", ["fs": fsRoot, "remote": item.path])
                }
            }
        }
    }

    func emptyTrash() {
        run(L("Emptying trash…")) { [self] in
            for item in try await list(trashPath) {
                if item.isDir {
                    _ = try await RcloneDaemon.shared.call("operations/purge", ["fs": fsRoot, "remote": item.path])
                } else {
                    _ = try await RcloneDaemon.shared.call("operations/deletefile", ["fs": fsRoot, "remote": item.path])
                }
            }
        }
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
        for item in selection {
            var target = folder.appendingPathComponent(item.name)
            if fm.fileExists(atPath: target.path) {
                let taken = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                target = folder.appendingPathComponent(RPath.uniqueName(item.name, taken: taken))
            }
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
                        let existing = (dest == cwd ? items : (try? await list(dest)) ?? []).first { $0.name == name }
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
