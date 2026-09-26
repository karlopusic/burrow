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

    var displayName: String { name.isEmpty ? "\(user)@\(host)" : name }
    var isComplete: Bool { !host.isEmpty && !user.isEmpty && (auth == .password || !keyFile.isEmpty) }

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

    static func set(_ password: String, for id: UUID) {
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
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ id: UUID) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: id.uuidString]
        SecItemDelete(q as CFDictionary)
    }
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
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
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
