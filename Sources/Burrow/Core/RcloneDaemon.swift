import Foundation
import Darwin

struct RcloneError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A long-running `rclone rcd` owned by the GUI. It keeps SFTP connections pooled (so browsing is fast)
/// and runs transfers as async jobs with per-job stats. It listens on 127.0.0.1 only, on a random port,
/// protected by random per-session credentials.
final class RcloneDaemon: @unchecked Sendable {
    static let shared = RcloneDaemon()

    private let lock = NSLock()
    private var process: Process?
    private var port = 0
    private let user = UUID().uuidString
    private let pass = UUID().uuidString
    private var obscured: [String: String] = [:]
    private static let pidFile = Paths.support + "/rcd.pid"

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: c)
    }()

    // MARK: lifecycle

    func startIfNeeded() throws {
        lock.lock(); defer { lock.unlock() }
        if let p = process, p.isRunning { return }
        Self.killStale()
        port = Self.freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.rclone)
        p.arguments = ["rcd",
                       "--rc-addr", "127.0.0.1:\(port)",
                       "--rc-job-expire-duration", "10m",
                       "--local-unicode-normalization",   // uploads use NFC names, like the backup
                       "--config", Paths.rcloneConf,
                       "--log-file", Paths.logs + "/rcd.log", "--log-level", "NOTICE",
                       "--retries", "3", "--low-level-retries", "10"]
        // Credentials go through the environment: command-line arguments are visible to every user on the Mac
        // (`ps`), and anyone holding them could drive this rclone – which runs with our files and SSH keys.
        p.environment = Self.environment(user: user, pass: pass)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        try? String(p.processIdentifier).write(toFile: Self.pidFile, atomically: true, encoding: .utf8)
        // wait until it answers
        for _ in 0..<50 {
            if (try? syncCall("rc/noop", [:])) != nil { return }
            usleep(100_000)
        }
        throw RcloneError(message: "rclone did not start")
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(atPath: Self.pidFile)
    }

    static func environment(user: String, pass: String,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("RCLONE_") }   // no inherited rclone settings or credentials
        env["RCLONE_RC_USER"] = user
        env["RCLONE_RC_PASS"] = pass
        return env
    }

    /// An rcd left behind by a crashed session would keep a port and SFTP connections open.
    private static func killStale() {
        guard let s = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = Int32(s), pidAlive(pid) else { return }
        let cmd = runCapture("/bin/ps", ["-p", String(pid), "-o", "command="]).out
        if cmd.contains("rclone") && cmd.contains(" rcd ") { kill(pid, SIGTERM) }
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    // MARK: calls

    private func request(_ command: String, _ params: [String: Any]) throws -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(command)")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Basic " + Data("\(user):\(pass)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        r.httpBody = try JSONSerialization.data(withJSONObject: params)
        return r
    }

    private static func decode(_ data: Data, _ response: URLResponse?) throws -> [String: Any] {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RcloneError(message: Self.clean(obj["error"] as? String ?? "HTTP \(http.statusCode)"))
        }
        return obj
    }

    /// rclone errors embed the whole connection string; strip it so messages stay readable.
    static func clean(_ msg: String) -> String {
        msg.replacingOccurrences(of: #":sftp,[^:]*:"#, with: "", options: .regularExpression)
    }

    func call(_ command: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        try startIfNeeded()
        let (data, resp) = try await session.data(for: try request(command, params))
        return try Self.decode(data, resp)
    }

    private func syncCall(_ command: String, _ params: [String: Any]) throws -> [String: Any] {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error> = .failure(RcloneError(message: "no response"))
        let task = session.dataTask(with: try request(command, params)) { d, r, e in
            if let e { result = .failure(e) } else { result = Result { try Self.decode(d ?? Data(), r) } }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 2)
        return try result.get()
    }

    // MARK: fs strings

    /// Connection-string remote (`:sftp,host=…:`) – nothing is written to rclone.conf, passwords stay in memory.
    func fsBase(_ b: Bookmark) async throws -> String {
        func q(_ v: String) -> String { "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var s = ":sftp,host=\(q(b.host)),user=\(q(b.user)),port=\(b.port),known_hosts_file=\(q(Paths.knownHosts)),shell_type=\(b.usesRemoteShell ? "unix" : "none"),idle_timeout=30m"
        switch b.auth {
        case .key:
            s += ",key_file=\(q(b.keyFile))"
        case .password:
            guard let pw = Keychain.get(b.id) else { throw RcloneError(message: L("No password saved for %@.", b.displayName)) }
            s += ",pass=\(q(try await obscure(pw)))"
        }
        return s + ":"
    }

    private func obscure(_ clear: String) async throws -> String {
        if let cached = lock.withLock({ obscured[clear] }) { return cached }
        let r = try await call("core/obscure", ["clear": clear])
        guard let o = r["obscured"] as? String else { throw RcloneError(message: "obscure failed") }
        lock.withLock { obscured[clear] = o }
        return o
    }
}
