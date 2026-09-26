import Foundation

/// Folder listings per server, so navigation can show a folder instantly and refresh it in the background
/// (stale-while-revalidate). Bounded: at most `memoryLimit` folders in memory (LRU) and the most recent
/// `diskLimit` folders / `diskItemLimit` entries persisted to ~/Library/Caches between launches.
@MainActor
final class DirCache {
    struct Entry: Codable {
        var items: [RemoteItem]
        var fetched: Date
    }

    static let memoryLimit = 1500
    static let diskLimit = 400
    static let diskItemLimit = 150_000
    static let maxItemsPerFolder = 20_000

    private static var registry: [UUID: DirCache] = [:]
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppInfo.name + "/Listings")

    /// One cache per bookmark, shared by every browser model created for it.
    static func forBookmark(_ id: UUID) -> DirCache {
        if let c = registry[id] { return c }
        let c = DirCache(file: folder.appendingPathComponent(id.uuidString + ".json"))
        registry[id] = c
        return c
    }

    /// Connection details changed or the bookmark was removed: forget everything we knew about it.
    static func discard(_ id: UUID) {
        registry[id] = nil
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id.uuidString + ".json"))
    }

    static func saveAll() { registry.values.forEach { $0.save() } }

    private let file: URL
    private var entries: [String: Entry] = [:]
    private var lru: [String] = []            // most recent last
    private var saveTask: Task<Void, Never>?

    private init(file: URL) {
        self.file = file
        if let d = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: d) {
            entries = saved
            lru = saved.sorted { $0.value.fetched < $1.value.fetched }.map(\.key)
        }
    }

    func get(_ dir: String) -> Entry? {
        guard let e = entries[dir] else { return nil }
        touch(dir)
        return e
    }

    /// Seconds since the folder was last fetched, nil if unknown.
    func age(_ dir: String) -> TimeInterval? {
        entries[dir].map { Date().timeIntervalSince($0.fetched) }
    }

    func put(_ dir: String, _ items: [RemoteItem]) {
        guard items.count <= Self.maxItemsPerFolder else { entries[dir] = nil; return }
        entries[dir] = Entry(items: items, fetched: Date())
        touch(dir)
        while lru.count > Self.memoryLimit { entries[lru.removeFirst()] = nil }
        scheduleSave()
    }

    /// Keep showing the old listing, but refetch it next time (it's known to have changed).
    func markStale(_ dir: String) {
        guard entries[dir] != nil else { return }
        entries[dir]?.fetched = .distantPast
        scheduleSave()
    }

    /// The folder (and everything below it) no longer exists at this path.
    func removeTree(_ dir: String) {
        let keys = entries.keys.filter { $0 == dir || dir.isEmpty || $0.hasPrefix(dir + "/") }
        for k in keys { entries[k] = nil }
        lru.removeAll { keys.contains($0) }
        scheduleSave()
    }

    private func touch(_ dir: String) {
        if let i = lru.lastIndex(of: dir) { lru.remove(at: i) }
        lru.append(dir)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        var out: [String: Entry] = [:]
        var total = 0
        for dir in lru.reversed() {
            guard let e = entries[dir], out.count < Self.diskLimit, total + e.items.count <= Self.diskItemLimit else { continue }
            out[dir] = e
            total += e.items.count
        }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(out) { try? d.write(to: file, options: .atomic) }
    }
}
