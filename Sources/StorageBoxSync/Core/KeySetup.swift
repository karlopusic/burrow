import Foundation

/// One-time onboarding: create a dedicated SSH key and append it to the Storage Box's authorized_keys
/// using the account password. The password is only held in memory and in a 0600 temp config that is
/// deleted immediately afterwards; scheduled backups authenticate with the key alone.
enum KeySetup {
    struct Outcome { let ok: Bool; let message: String }

    static func run(host: String, port: Int, user: String, password: String, keyFile: String) -> Outcome {
        let fm = FileManager.default
        Paths.ensure()

        // 1. Trust the host key (TOFU) so rclone can verify the server from now on.
        let hostEntry = port == 22 ? host : "[\(host)]:\(port)"
        if runCapture("/usr/bin/ssh-keygen", ["-F", hostEntry, "-f", Paths.knownHosts]).code != 0 {
            let scan = runCapture("/usr/bin/ssh-keyscan", ["-p", String(port), "-t", "ed25519,rsa", host])
            guard scan.code == 0, !scan.out.isEmpty else {
                return Outcome(ok: false, message: L("Could not reach %@ on port %ld.", host, port))
            }
            if let h = FileHandle(forWritingAtPath: Paths.knownHosts) ?? {
                fm.createFile(atPath: Paths.knownHosts, contents: nil, attributes: [.posixPermissions: 0o600])
                return FileHandle(forWritingAtPath: Paths.knownHosts)
            }() {
                h.seekToEndOfFile(); h.write(Data(scan.out.utf8)); try? h.close()
            }
        }

        // 2. Dedicated key without passphrase (needed for unattended runs).
        if !fm.fileExists(atPath: keyFile) {
            let host = ProcessInfo.processInfo.hostName
            let r = runCapture("/usr/bin/ssh-keygen", ["-t", "ed25519", "-N", "", "-q", "-C", "storagebox-sync@\(host)", "-f", keyFile])
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
        let conf = """
        [setup]
        type = sftp
        host = \(host)
        port = \(port)
        user = \(user)
        pass = \(obscured.out.trimmingCharacters(in: .whitespacesAndNewlines))
        known_hosts_file = \(Paths.knownHosts)
        shell_type = unix

        """
        fm.createFile(atPath: tmpConf, contents: Data(conf.utf8), attributes: [.posixPermissions: 0o600])
        defer { try? fm.removeItem(atPath: tmpConf) }

        // 4. Append (never replace) our key in .ssh/authorized_keys.
        let probe = rclone(["lsf", "--max-depth", "1", "setup:"], config: tmpConf)
        guard probe.code == 0 else {
            return Outcome(ok: false, message: L("Login failed: %@", lastErrorLine(probe.err)))
        }
        rclone(["mkdir", "setup:.ssh"], config: tmpConf)
        let existing = rclone(["cat", "setup:.ssh/authorized_keys"], config: tmpConf)
        var keys = existing.code == 0 ? existing.out : ""
        let keyCore = pub.split(separator: " ").prefix(2).joined(separator: " ")
        if !keys.contains(keyCore) {
            if !keys.isEmpty && !keys.hasSuffix("\n") { keys += "\n" }
            keys += pub + "\n"
            let tmpKeys = Paths.support + "/authorized_keys.tmp"
            try? keys.write(toFile: tmpKeys, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(atPath: tmpKeys) }
            let up = rclone(["copyto", tmpKeys, "setup:.ssh/authorized_keys"], config: tmpConf)
            guard up.code == 0 else {
                return Outcome(ok: false, message: L("Could not upload the key: %@", lastErrorLine(up.err)))
            }
        }
        return Outcome(ok: true, message: L("SSH key installed. The password is no longer needed."))
    }
}
