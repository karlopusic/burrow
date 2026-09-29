import Foundation
import Security

/// A saved SFTP server, like a Cyberduck bookmark.
struct Bookmark: Codable, Identifiable, Hashable {
    enum Auth: String, Codable, CaseIterable { case key, password }

    var id = UUID()
    var name = ""
    var host = ""
    var port = 22
    var user = ""
    var auth: Auth = .key
    var keyFile = Paths.home + "/.ssh/id_ed25519"
    /// Start folder. Relative paths are relative to the login folder; absolute paths start at "/".
    var path = ""
    /// Folder (relative to the login folder) where "Delete" moves items.
    var trashFolder = ".burrow-trash"
    /// nil preserves the behavior of existing Hetzner bookmarks.
    var remoteShell: Bool? = nil

    var displayName: String { name.isEmpty ? "\(user)@\(host)" : name }
    var isComplete: Bool { !host.isEmpty && !user.isEmpty && (auth == .password || !keyFile.isEmpty) }
    var usesRemoteShell: Bool { remoteShell ?? host.hasSuffix(".your-storagebox.de") }

    /// Why "Delete" can't use this trash folder, or nil. Emptying the trash deletes everything in it for good,
    /// so it must be a dedicated folder. `protected`: the backup and versions folders, when this is the backup server.
    func trashProblem(protecting protected: [String]) -> String? {
        let parts = trashFolder.split(separator: "/")
        if parts.isEmpty { return L("Choose a trash folder.") }
        // the folder "Delete" really uses: inside the start folder for absolute bookmarks (BrowserModel.trashPath)
        let trash = path.hasPrefix("/") ? "/" + RPath.join(path, trashFolder) : RPath.join(trashFolder)
        if trash.split(separator: "/").contains(where: { $0 == "." || $0 == ".." || $0 == "~" }) {
            return L("Folder paths cannot contain dot or parent-directory segments.")
        }
        if trash == "/home" { return L("Choose a trash folder.") }
        let others = protected.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if others.contains(where: { RPath.mayOverlap(trash, $0) }) {
            return L("The trash folder must be outside the backup and versions folders.")
        }
        return nil
    }

    static func storageBox(user: String, keyFile: String) -> Bookmark {
        var b = Bookmark()
        b.name = "Storage Box"
        b.host = "\(user).your-storagebox.de"
        b.user = user
        b.port = 23
        b.keyFile = keyFile
        return b
    }
}

enum BookmarkStore {
    static let file = Paths.support + "/bookmarks.json"

    static func load() -> [Bookmark] {
        guard let d = FileManager.default.contents(atPath: file),
              let b = try? JSONDecoder().decode([Bookmark].self, from: d) else { return [] }
        return b
    }

    static func save(_ list: [Bookmark]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(list) { try? d.write(to: URL(fileURLWithPath: file), options: .atomic) }
    }
}

/// Passwords for password-auth bookmarks live only in the login Keychain.
enum Keychain {
    static let service = AppInfo.bundleID + ".sftp"

    /// Read once per launch: every Keychain read can raise its own "wants to use your confidential information"
    /// prompt (always, for ad-hoc signed builds), and one connection used to read it several times.
    private static var cache: [UUID: String] = [:]
    private static let lock = NSLock()

    @discardableResult
    static func set(_ password: String, for id: UUID) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString]
        var add = q
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "\(AppInfo.name) SFTP password"
        let result = SecItemAdd(add as CFDictionary, nil)
        let status = result == errSecDuplicateItem
            ? SecItemUpdate(q as CFDictionary, [kSecValueData as String: Data(password.utf8)] as CFDictionary)
            : result
        guard status == errSecSuccess else { return false }
        lock.withLock { cache[id] = password }
        return true
    }

    /// `service` other than the default is only used to migrate items saved under the app's former name.
    static func get(_ id: UUID, service: String = Keychain.service) -> String? {
        lock.lock(); defer { lock.unlock() }      // held during the lookup, so parallel callers share one prompt
        let isDefault = service == Self.service
        if isDefault, let pw = cache[id] { return pw }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let pw = String(data: d, encoding: .utf8) else { return nil }
        if isDefault { cache[id] = pw }
        return pw
    }

    static func delete(_ id: UUID) {
        lock.withLock { cache[id] = nil }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString]
        SecItemDelete(q as CFDictionary)
    }
}

extension String {
    /// Unicode NFC. Names are only ever written to the server in this form: the SFTP server treats the NFD spelling
    /// of the same name as a different file, and rclone then ignores one of the two ("Duplicate … found").
    var nfc: String { precomposedStringWithCanonicalMapping }
}

/// Paths inside a browser are always relative to the bookmark's fs root and use "/" as separator.
enum RPath {
    static func join(_ parts: String...) -> String {
        parts.flatMap { $0.split(separator: "/").map(String.init) }.joined(separator: "/")
    }
    static func parent(_ p: String) -> String {
        guard let i = p.lastIndex(of: "/") else { return "" }
        return String(p[..<i])
    }
    static func name(_ p: String) -> String {
        p.split(separator: "/").last.map(String.init) ?? p
    }
    /// Whether two server folders may be the same folder or nested. Relative paths start at the login folder, which
    /// isn't known here: a relative path overlaps an absolute one when it could continue it below some login folder
    /// (`/home/P/v` and `P`). A false alarm only means choosing another folder name.
    static func mayOverlap(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: "/")[...], pb = b.split(separator: "/")[...]
        func nested(_ x: ArraySlice<Substring>, _ y: ArraySlice<Substring>) -> Bool { x.starts(with: y) || y.starts(with: x) }
        switch (a.hasPrefix("/"), b.hasPrefix("/")) {
        case (true, false): return pa.indices.contains { nested(pa[$0...], pb) }
        case (false, true): return pb.indices.contains { nested(pb[$0...], pa) }
        default: return nested(pa, pb)
        }
    }
    /// How names are compared for conflicts: NFC, so "š" typed as one character and as s + combining caron are the
    /// same name, and ignoring case, because on macOS or Windows servers `a.txt` and `A.txt` are one file. On other
    /// servers the worst case is an unneeded "Keep Both".
    static func conflictKey(_ name: String) -> String { name.nfc.lowercased() }
    static func isTaken(_ name: String, _ taken: Set<String>) -> Bool {
        let key = conflictKey(name)
        return taken.contains { conflictKey($0) == key }
    }

    /// "Report.pdf" → "Report 2.pdf", "Folder" → "Folder 2", avoiding names in `taken` (see `conflictKey`).
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let name = name.nfc, taken = Set(taken.map(conflictKey))
        guard taken.contains(conflictKey(name)) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(conflictKey(candidate)) { return candidate }
            n += 1
        }
    }
}
