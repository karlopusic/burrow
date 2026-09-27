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
    var trashFolder = ".sbs-trash"
    /// nil preserves the behavior of existing Hetzner bookmarks.
    var remoteShell: Bool? = nil

    var displayName: String { name.isEmpty ? "\(user)@\(host)" : name }
    var isComplete: Bool { !host.isEmpty && !user.isEmpty && (auth == .password || !keyFile.isEmpty) }
    var usesRemoteShell: Bool { remoteShell ?? host.hasSuffix(".your-storagebox.de") }

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

    static func set(_ password: String, for id: UUID) {
        lock.withLock { cache[id] = password }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "\(AppInfo.name) SFTP password"
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }      // held during the lookup, so parallel callers share one prompt
        if let pw = cache[id] { return pw }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let pw = String(data: d, encoding: .utf8) else { return nil }
        cache[id] = pw
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
    /// "Report.pdf" → "Report 2.pdf", "Folder" → "Folder 2", avoiding names in `taken`.
    /// Compares in NFC, so "š" typed as one character and as s + combining caron count as the same name.
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let name = name.nfc, taken = Set(taken.map(\.nfc))
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }
}
