import Foundation

/// End-to-end test of the browser + transfer code paths against a real SFTP server, inside a throw-away
/// folder that is created and removed by the test:
///
///   Burrow --selftest <host> <port> <user> <keyfile>
///
/// Uses `_sbs_selftest_<random>` in the login folder; nothing else on the server is touched.
@MainActor
enum SelfTest {
    static var failures = 0
    static var current: BrowserModel?

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "PASS  \(what)" : "FAIL  \(what)")
        if !ok {
            failures += 1
            if let m = current {
                print("      error: \(m.error ?? "-")  cwd: \(m.cwd)  items: \(m.items.map { "\($0.name)(\($0.size))" })")
                for t in TransferManager.shared.items.prefix(3) { print("      transfer \(t.name): \(t.state) \(t.error ?? "")") }
            }
        }
    }

    static func waitIdle(_ m: BrowserModel, timeout: Double = 120) async {
        let end = Date().addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: 200_000_000)
        while (m.busy != nil || m.loading || m.refreshing || m.pendingOps > 0) && Date() < end { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    static func waitTransfers(timeout: Double = 300) async {
        let end = Date().addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: 500_000_000)
        while (TransferManager.shared.activeCount > 0 || (current?.pendingOps ?? 0) > 0) && Date() < end { try? await Task.sleep(nanoseconds: 300_000_000) }
    }

    static func names(_ m: BrowserModel, _ dir: String) async -> Set<String> {
        Set(((try? await m.list(dir)) ?? []).map(\.name))
    }

    static func run(_ args: [String]) async -> Int32 {
        guard args.count >= 4, let port = Int(args[1]) else {
            print("usage: --selftest <host> <port> <user> <keyfile>"); return 2
        }
        Paths.ensure()
        let root = "_sbs_selftest_\(Int.random(in: 1000...9999))"
        var b = Bookmark()
        b.name = "selftest"; b.host = args[0]; b.port = port; b.user = args[2]; b.keyFile = args[3]
        b.path = root
        b.trashFolder = root + "/.trash"
        defer { UserDefaults.standard.removeObject(forKey: "lastPath.\(b.id.uuidString)") }   // shared with the real app

        // local fixtures
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("sbs-selftest-\(UUID().uuidString)")
        let dir = local.appendingPathComponent("Folder A")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try? "one".write(to: local.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        try? "two".write(to: dir.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        try? "three".write(to: dir.appendingPathComponent("Sub/deep.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: local) }

        do {
            let base = try await RcloneDaemon.shared.fsBase(b)
            _ = try await RcloneDaemon.shared.call("operations/mkdir", ["fs": base, "remote": root])
        } catch { print("FAIL  connect: \(error.localizedDescription)"); return 1 }

        let m = BrowserModel(bookmark: b)
        current = m
        await m.connect()
        check(m.error == nil && m.items.isEmpty, "connect + list empty folder")

        m.newFolder("New Folder")
        await waitIdle(m)
        check(m.items.contains { $0.name == "New Folder" && $0.isDir }, "new folder")

        m.upload([local.appendingPathComponent("report.txt"), dir], choose: { _ in .skip })
        await waitTransfers(); await m.reload()
        check(Set(m.items.map(\.name)).isSuperset(of: ["report.txt", "Folder A"]), "upload file + folder")
        check(await names(m, root + "/Folder A/Sub") == ["deep.txt"], "upload keeps folder structure")
        check(TransferManager.shared.items.prefix(2).allSatisfy { $0.state == .done }, "transfers reported done")

        // conflict: keep both
        m.upload([local.appendingPathComponent("report.txt")], choose: { _ in .keepBoth })
        await waitTransfers(); await m.reload()
        check(m.items.contains { $0.name == "report 2.txt" }, "upload conflict → keep both")

        // conflict: replace (old copy must land in trash)
        try? "one-v2".write(to: local.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        m.upload([local.appendingPathComponent("report.txt")], choose: { _ in .replace })
        await waitTransfers(); await m.reload()
        let size = m.items.first { $0.name == "report.txt" }?.size
        check(size == 6, "upload conflict → replace uploads new version")
        let trashList = (try? await RcloneDaemon.shared.call("operations/list",
            ["fs": try await RcloneDaemon.shared.fsBase(b), "remote": b.trashFolder, "opt": ["recurse": true]])["list"] as? [[String: Any]]) ?? []
        check(trashList.contains { ($0["Name"] as? String) == "report.txt" }, "replace → old version kept in trash")

        // rename file + folder
        if let f = m.items.first(where: { $0.name == "report 2.txt" }) { m.rename(f, to: "renamed.txt") }
        await waitIdle(m)
        if let d = m.items.first(where: { $0.name == "New Folder" }) { m.rename(d, to: "Renamed Folder") }
        await waitIdle(m)
        let n1 = Set(m.items.map(\.name))
        check(n1.contains("renamed.txt") && !n1.contains("report 2.txt"), "rename file")
        check(n1.contains("Renamed Folder") && !n1.contains("New Folder"), "rename folder")

        // rename onto an existing name must be refused
        if let f = m.items.first(where: { $0.name == "renamed.txt" }) { m.rename(f, to: "report.txt") }
        await waitIdle(m)
        check(m.error != nil && m.items.first { $0.name == "report.txt" }?.size == 6, "rename refuses to overwrite")
        m.error = nil

        // Unicode: NFD names (s + combining caron) are stored as NFC, and both spellings count as one name.
        // String == treats the two as equal, so compare scalars.
        func stored(_ name: String) -> Bool { m.items.contains { $0.name.unicodeScalars.elementsEqual(name.nfc.unicodeScalars) } }
        let nfdFile = "Izvjes\u{030C}taj.txt"
        try? "u".write(to: local.appendingPathComponent(nfdFile), atomically: true, encoding: .utf8)
        m.upload([local.appendingPathComponent(nfdFile)], choose: { _ in .skip })
        await waitTransfers(); await m.reload()
        check(stored(nfdFile), "upload stores an NFD file name as NFC")
        m.newFolder("Obic\u{030C}na mapa")
        await waitIdle(m)
        check(stored("Obic\u{030C}na mapa"), "new folder stores an NFD name as NFC")
        m.newFolder("Obična mapa")
        await waitIdle(m)
        check(m.error != nil && m.items.filter { $0.name.nfc == "Obična mapa" }.count == 1,
              "new folder refuses the other spelling of an existing name")
        m.error = nil

        // duplicate
        if let f = m.items.first(where: { $0.name == "renamed.txt" }) { m.duplicate([f]) }
        await waitTransfers(); await m.reload()
        check(m.items.contains { $0.name == "renamed 2.txt" }, "duplicate file")

        // cut/paste folder into another folder
        if let d = m.items.first(where: { $0.name == "Folder A" }) { m.cut([d]) }
        m.open(root + "/Renamed Folder"); await waitIdle(m)
        m.paste(); await waitIdle(m)
        check(m.items.contains { $0.name == "Folder A" && $0.isDir }, "cut + paste folder")
        check(await names(m, root + "/Renamed Folder/Folder A/Sub") == ["deep.txt"], "moved folder keeps contents")
        check(!(await names(m, root)).contains("Folder A"), "moved folder removed from source")

        // search
        m.open(root); await waitIdle(m)
        m.searchText = "deep"; m.search()
        try? await Task.sleep(nanoseconds: 300_000_000)
        while m.searching { try? await Task.sleep(nanoseconds: 200_000_000) }
        check(m.searchResults?.map(\.name) == ["deep.txt"], "recursive search")
        m.clearSearch()

        // trash + put back
        if let f = m.items.first(where: { $0.name == "renamed.txt" }) { m.moveToTrash([f]) }
        await waitIdle(m)
        check(!m.items.contains { $0.name == "renamed.txt" }, "move to trash removes item")
        m.openTrash(); await waitIdle(m)
        let stampDirs = m.items.filter(\.isDir).sorted { $0.name > $1.name }
        check(stampDirs.count >= 2, "trash has dated folders (replace + delete)")
        if let s = stampDirs.first {
            m.open(s.path); await waitIdle(m)
            let trashed = m.items.first { $0.name == "renamed.txt" }
            check(trashed != nil, "deleted item sits directly in its dated trash folder")
            check(trashed.flatMap { m.originalPath($0) } == root + "/renamed.txt", "trash remembers original path")
            if let t = trashed { m.putBack([t]) }
            await waitIdle(m)
        }
        check(await names(m, root).contains("renamed.txt"), "put back restores item")

        // put back a whole dated folder: the "Replace" step's old report.txt returns next to the new one
        m.openTrash(); await waitIdle(m)
        if let oldest = m.items.filter(\.isDir).sorted(by: { $0.name < $1.name }).first { m.putBack([oldest]) }
        await waitIdle(m)
        let restored = try? await m.list(root)
        check(restored?.first { $0.name == "report 2.txt" }?.size == 3, "put back whole dated folder (keeps both names)")
        check((await names(m, b.trashFolder)).isEmpty, "empty dated folders are removed after put back")

        // quick look download
        m.open(root); await waitIdle(m)
        if let f = m.items.first(where: { $0.name == "report.txt" }) { m.quickLook(f) }
        await waitIdle(m)
        let preview = m.quickLookURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        check(preview == "one-v2", "quick look downloads file")

        // download folder
        let dl = local.appendingPathComponent("downloads")
        try? FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        if let d = m.items.first(where: { $0.name == "Renamed Folder" }) { m.download([d], to: dl) }
        await waitTransfers()
        check(FileManager.default.fileExists(atPath: dl.path + "/Renamed Folder/Folder A/Sub/deep.txt"), "download folder")

        // cache: prefetched subfolder and "Back" open instantly; outside changes appear after the background refresh
        m.open(root); await waitIdle(m)
        try? await Task.sleep(nanoseconds: 4_000_000_000)          // let prefetch of subfolders finish
        let sub = root + "/Renamed Folder"
        let t0 = Date()
        m.open(sub)
        let instant = !m.items.isEmpty && !m.loading
        check(instant && Date().timeIntervalSince(t0) < 0.05, "prefetched subfolder opens instantly from cache")
        await waitIdle(m)
        m.goBack()
        check(!m.items.isEmpty && !m.loading, "back is instant from cache")
        await waitIdle(m)
        if let base = try? await RcloneDaemon.shared.fsBase(b) {   // change made "by someone else"
            _ = try? await RcloneDaemon.shared.call("operations/mkdir", ["fs": base, "remote": sub + "/External"])
        }
        m.open(sub)
        let staleFirst = !m.items.contains { $0.name == "External" }
        await waitIdle(m)
        check(staleFirst && m.items.contains { $0.name == "External" }, "background refresh picks up outside changes")
        m.open(root); await waitIdle(m)

        // cancelled upload leaves no partial file
        let big = local.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: Data(count: 300 * 1024 * 1024))
        m.upload([big], choose: { _ in .skip })
        // Cancel as soon as data flows: on a fast (local) server a fixed wait lets the upload finish first.
        let started = Date()
        var cancelledMidway = false
        while Date().timeIntervalSince(started) < 60 {
            if let t = TransferManager.shared.items.first(where: { $0.name == "big.bin" }) {
                if t.state == .running && t.bytes > 0 { TransferManager.shared.cancel(t.id); cancelledMidway = true; break }
                if t.state == .done { break }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let afterCancel = await names(m, root)
        if cancelledMidway {
            check(!afterCancel.contains { $0.hasSuffix(".partial") } && !afterCancel.contains("big.bin"), "cancel cleans up partial upload")
        } else {
            // Progress is polled once a second; an unthrottled local server finishes 300 MB before that.
            print("SKIP  cancel cleans up partial upload (the upload finished before it could be cancelled – server too fast)")
            check(!afterCancel.contains { $0.hasSuffix(".partial") }, "finished upload leaves no partial file")
        }

        // empty trash
        m.emptyTrash(); await waitIdle(m)
        check((await names(m, b.trashFolder)).isEmpty, "empty trash")

        // cleanup
        if let base = try? await RcloneDaemon.shared.fsBase(b) {
            _ = try? await RcloneDaemon.shared.call("operations/purge", ["fs": base, "remote": root])
        }
        DirCache.discard(b.id)
        UserDefaults.standard.removeObject(forKey: "lastPath.\(b.id.uuidString)")
        RcloneDaemon.shared.stop()
        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
