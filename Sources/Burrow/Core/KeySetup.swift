import Foundation

/// One-time onboarding: create a dedicated SSH key and install it only when authorized_keys is absent.
/// Existing key lists need a manual append because SFTP read/modify/write can discard concurrent changes.
/// The password is only held in memory and in a 0600 temp config that is
/// deleted immediately afterwards; scheduled backups authenticate with the key alone.
enum KeySetup {
    struct Outcome { let ok: Bool; let message: String }

    static func run(host: String, port: Int, user: String, password: String, keyFile: String) -> Outcome {
        let fm = FileManager.default
        Paths.ensure()

        // 1. The host key must already be trusted – the UI shows its fingerprint first (HostKeys).
        guard HostKeys.isKnown(host: host, port: port) else {
            return Outcome(ok: false, message: L("The server's identity has not been confirmed yet."))
        }

        // 2. Dedicated key without passphrase (needed for unattended runs).
        if !fm.fileExists(atPath: keyFile) {
            let host = ProcessInfo.processInfo.hostName
            let r = runCapture("/usr/bin/ssh-keygen", ["-t", "ed25519", "-N", "", "-q", "-C", "burrow@\(host)", "-f", keyFile])
            guard r.code == 0 else { return Outcome(ok: false, message: L("Could not create SSH key: %@", r.err)) }
        }
        guard let pub = try? String(contentsOfFile: keyFile + ".pub", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return Outcome(ok: false, message: L("Public key %@ is missing.", keyFile + ".pub"))
        }

        // 3. Temporary password-based rclone config.
        let obscured = runCapture(Paths.rclone, ["obscure", "-"], stdin: password)
        guard obscured.code == 0 else { return Outcome(ok: false, message: lastErrorLine(obscured.err)) }
        let tmpConf = Paths.support + "/setup-\(UUID().uuidString).conf"
        func line(_ s: String) -> String { s.components(separatedBy: .newlines).joined() }
        let conf = """
        [setup]
        type = sftp
        host = \(line(host))
        port = \(port)
        user = \(line(user))
        pass = \(obscured.out.trimmingCharacters(in: .whitespacesAndNewlines))
        known_hosts_file = \(Paths.knownHosts)
        shell_type = unix

        """
        fm.createFile(atPath: tmpConf, contents: Data(conf.utf8), attributes: [.posixPermissions: 0o600])
        defer { try? fm.removeItem(atPath: tmpConf) }

        // 4. Create a new authorized_keys only. Never replace an existing list of keys.
        let probe = rclone(["lsf", "--max-depth", "1", "setup:"], config: tmpConf)
        guard probe.code == 0 else {
            return Outcome(ok: false, message: L("Login failed: %@", lastErrorLine(probe.err)))
        }
        rclone(["mkdir", "setup:.ssh"], config: tmpConf)
        let existing = rclone(["cat", "setup:.ssh/authorized_keys"], config: tmpConf)
        guard existingKeys(existing) != nil else {
            // Any other failure (timeout, permissions) must not be mistaken for "no keys yet": uploading
            // then would replace the file and lock the user out of every other key they had.
            return Outcome(ok: false, message: L("Could not read the existing keys on the server: %@", lastErrorLine(existing.err)))
        }
        let keyCore = pub.split(separator: " ").prefix(2).joined(separator: " ")
        if keyAction(existing: existing, publicKeyCore: keyCore) == .alreadyInstalled {
            return Outcome(ok: true, message: L("SSH key installed. The password is no longer needed."))
        }
        guard keyAction(existing: existing, publicKeyCore: keyCore) == .create else {
            return Outcome(ok: false, message: L("Append the public key from %@ to the existing .ssh/authorized_keys on the server, then check the connection.", keyFile + ".pub"))
        }
        let tmpKeys = Paths.support + "/authorized_keys-\(UUID().uuidString).tmp"
        fm.createFile(atPath: tmpKeys, contents: Data((pub + "\n").utf8), attributes: [.posixPermissions: 0o600])
        defer { try? fm.removeItem(atPath: tmpKeys) }
        let up = rclone(["copyto", tmpKeys, "setup:.ssh/authorized_keys", "--ignore-existing"], config: tmpConf)
        guard up.code == 0 else {
            return Outcome(ok: false, message: L("Could not upload the key: %@", lastErrorLine(up.err)))
        }
        let installed = rclone(["cat", "setup:.ssh/authorized_keys"], config: tmpConf)
        guard installed.code == 0, installed.out.contains(keyCore) else {
            return Outcome(ok: false, message: L("The server's key file changed during setup. Check its contents and try again."))
        }
        return Outcome(ok: true, message: L("SSH key installed. The password is no longer needed."))
    }

    enum KeyAction { case alreadyInstalled, create, manual }
    static func keyAction(existing: ShellResult, publicKeyCore: String) -> KeyAction {
        guard let current = existingKeys(existing) else { return .manual }
        let installed = current.split(whereSeparator: \.isNewline).contains { line in
            line.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ") == publicKeyCore
        }
        if installed { return .alreadyInstalled }
        return existing.code == 0 ? .manual : .create
    }

    /// Content of the server's authorized_keys from `rclone cat`: "" only when the file (or .ssh) doesn't exist
    /// (rclone exit 3 = directory not found, 4 = file not found), nil for every other failure.
    static func existingKeys(_ r: ShellResult) -> String? {
        switch r.code {
        case 0: return r.out
        case 3, 4: return ""
        default:
            let e = r.err.lowercased()
            return e.contains("object not found") || e.contains("file does not exist") || e.contains("directory not found") ? "" : nil
        }
    }
}
