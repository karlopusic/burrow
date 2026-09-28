import Foundation

/// SSH host-key verification. rclone checks every connection against ~/.ssh/known_hosts, so a server has to be
/// trusted once – and only after the user has compared its fingerprint with the one the provider publishes.
enum HostKeys {
    struct Key: Identifiable, Hashable {
        var id: String { line }
        let line: String          // known_hosts line as printed by ssh-keyscan
        let type: String          // ED25519, ECDSA, RSA
        let fingerprint: String   // SHA256:…
    }

    enum Scan {
        case keys([Key])
        case failed(String)
    }

    static func entry(host: String, port: Int) -> String { port == 22 ? host : "[\(host)]:\(port)" }

    static func isKnown(host: String, port: Int) -> Bool {
        runCapture("/usr/bin/ssh-keygen", ["-F", entry(host: host, port: port), "-f", Paths.knownHosts]).code == 0
    }

    /// Fetches the server's host keys and their SHA256 fingerprints. Nothing is written.
    static func scan(host: String, port: Int) -> Scan {
        let r = runCapture("/usr/bin/ssh-keyscan", ["-T", "10", "-p", String(port), "-t", "ed25519,ecdsa,rsa", host])
        let lines = r.out.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        guard !lines.isEmpty else { return .failed(L("Could not reach %@ on port %ld.", host, port)) }
        var keys: [Key] = []
        for line in lines {
            // "256 SHA256:abc… [host]:23 (ED25519)"
            let fp = runCapture("/usr/bin/ssh-keygen", ["-l", "-f", "-"], stdin: line + "\n").out
            let parts = fp.split(separator: " ")
            guard parts.count >= 3, let sha = parts.first(where: { $0.hasPrefix("SHA256:") }) else { continue }
            let type = parts.last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()\n")) } ?? ""
            keys.append(Key(line: line, type: type, fingerprint: String(sha)))
        }
        let order = ["ED25519": 0, "ECDSA": 1, "RSA": 2]
        keys.sort { (order[$0.type] ?? 9) < (order[$1.type] ?? 9) }
        return keys.isEmpty ? .failed(L("Could not read the host keys of %@.", host)) : .keys(keys)
    }

    /// Appends the confirmed keys to known_hosts (never rewrites existing entries).
    static func trust(_ keys: [Key]) {
        Paths.ensure()
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.knownHosts) {
            fm.createFile(atPath: Paths.knownHosts, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forWritingAtPath: Paths.knownHosts) else { return }
        defer { try? h.close() }
        h.seekToEndOfFile()
        let existing = (try? String(contentsOfFile: Paths.knownHosts, encoding: .utf8)) ?? ""
        let prefix = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        h.write(Data((prefix + keys.map(\.line).joined(separator: "\n") + "\n").utf8))
    }

    /// Recognizes rclone/ssh errors caused by host-key checking.
    enum Problem { case unknown, changed }
    static func problem(in message: String?) -> Problem? {
        guard let m = message?.lowercased() else { return nil }
        if m.contains("key is unknown") { return .unknown }
        if m.contains("key mismatch") { return .changed }
        return nil
    }
}
