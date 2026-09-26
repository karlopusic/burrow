import Foundation

/// Imports settings and history from the pre-release prototype ("SIM Backup", bundle hr.push.simbackup).
/// Runs once, only while that prototype is idle, and never touches remote data.
enum LegacyMigration {
    static let legacySupport = Paths.home + "/Library/Application Support/SIM Backup"
    static let legacyLogs = Paths.home + "/Library/Logs/SIM Backup"
    static let legacyLabel = "hr.push.simbackup"
    static let legacyPlist = Paths.home + "/Library/LaunchAgents/hr.push.simbackup.plist"

    enum State { case none, waitingForLegacyRun, migrated }

    static func runIfNeeded() -> State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacySupport + "/config.json"),
              !fm.fileExists(atPath: Paths.config) else { return .none }

        // A backup started by the prototype is still running – try again on a later launch.
        if let d = fm.contents(atPath: legacySupport + "/status.json"),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let running = j["running"] as? [String: Any],
           let pid = (running["pid"] as? NSNumber)?.int32Value, pidAlive(pid) {
            return .waitingForLegacyRun
        }

        Paths.ensure()

        // Config: same keys, plus connection details from the old rclone.conf.
        var cfg = (fm.contents(atPath: legacySupport + "/config.json"))
            .flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) } ?? AppConfig()
        if let conf = try? String(contentsOfFile: legacySupport + "/rclone.conf", encoding: .utf8) {
            for line in conf.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "host": cfg.host = parts[1]
                case "port": cfg.port = Int(parts[1]) ?? cfg.port
                case "user": cfg.user = parts[1]
                case "key_file": cfg.keyFile = parts[1]
                default: break
                }
            }
        }
        cfg.save()

        // Logs.
        if let files = try? fm.contentsOfDirectory(atPath: legacyLogs) {
            for f in files where !fm.fileExists(atPath: Paths.logs + "/" + f) {
                try? fm.copyItem(atPath: legacyLogs + "/" + f, toPath: Paths.logs + "/" + f)
            }
        }

        // History: translate the prototype's Croatian enum values and re-point log paths.
        if let d = fm.contents(atPath: legacySupport + "/status.json"),
           var j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let runs = (j["runs"] as? [[String: Any]] ?? []).map { r -> [String: Any] in
                var r = r
                r["trigger"] = (r["trigger"] as? String) == "raspored" ? "schedule" : "manual"
                if let lf = r["logFile"] as? String { r["logFile"] = lf.replacingOccurrences(of: legacyLogs, with: Paths.logs) }
                return r
            }
            j["runs"] = runs
            j["running"] = nil
            if let out = try? JSONSerialization.data(withJSONObject: j) {
                try? out.write(to: URL(fileURLWithPath: Paths.status))
            }
        }

        Agent.remove(label: legacyLabel, plist: legacyPlist)
        try? fm.moveItem(atPath: legacySupport, toPath: legacySupport + " (migrated)")
        return .migrated
    }
}
