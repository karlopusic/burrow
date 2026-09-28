import Foundation

/// Moves an installation of "StorageBox Sync" (bundle hr.push.storageboxsync), the app's name before 0.4, to Burrow:
/// settings, run history, logs, server bookmarks and their Keychain passwords, preferences and the schedule.
/// Runs once, only while no old backup is running, and never touches remote data. The old folders are renamed
/// to "… (migrated)" instead of deleted, and old Keychain items are left in place, so nothing is lost.
enum RenameMigration {
    static let oldName = "StorageBox Sync"
    static let oldBundleID = "hr.push.storageboxsync"
    static var oldSupport: String { Paths.home + "/Library/Application Support/\(oldName)" }
    static var oldLogs: String { Paths.home + "/Library/Logs/\(oldName)" }
    /// Same rule as AppInfo.agentLabel: a dev instance with a throw-away home only ever sees the dev agent.
    static var oldLabel: String {
        ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == nil ? oldBundleID : oldBundleID + ".dev"
    }
    static var oldPlist: String { Paths.home + "/Library/LaunchAgents/\(oldLabel).plist" }

    static var isPending: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: oldSupport + "/config.json") && !fm.fileExists(atPath: Paths.config)
    }

    /// Preferences live in the old bundle's defaults domain. Called at the very start of main(), before the UI
    /// language is applied, so a migrated language takes effect immediately.
    static func migrateDefaults() {
        guard isPending, let old = UserDefaults(suiteName: oldBundleID) else { return }
        let skip = ["NS", "SU", "Apple", "com.apple"]
        for (key, value) in old.dictionaryRepresentation()
        where !skip.contains(where: { key.hasPrefix($0) }) && UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    static func runIfNeeded() -> LegacyMigration.State {
        guard isPending else { return .none }
        let fm = FileManager.default

        // A backup started by the old app is still running – try again on a later launch.
        if let d = fm.contents(atPath: oldSupport + "/status.json"),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let running = j["running"] as? [String: Any],
           let pid = (running["pid"] as? NSNumber)?.int32Value, pidAlive(pid) {
            return .waitingForLegacyRun
        }

        Paths.ensure()
        for f in ["config.json", "bookmarks.json", "transfers.json"] where !fm.fileExists(atPath: Paths.support + "/" + f) {
            try? fm.copyItem(atPath: oldSupport + "/" + f, toPath: Paths.support + "/" + f)
        }
        if let files = try? fm.contentsOfDirectory(atPath: oldLogs) {
            for f in files where !fm.fileExists(atPath: Paths.logs + "/" + f) {
                try? fm.copyItem(atPath: oldLogs + "/" + f, toPath: Paths.logs + "/" + f)
            }
        }
        // History: log paths point into the old Logs folder.
        if let d = fm.contents(atPath: oldSupport + "/status.json"),
           var j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            j["runs"] = (j["runs"] as? [[String: Any]] ?? []).map { r -> [String: Any] in
                var r = r
                if let lf = r["logFile"] as? String { r["logFile"] = lf.replacingOccurrences(of: oldLogs, with: Paths.logs) }
                return r
            }
            j["running"] = nil
            if let out = try? JSONSerialization.data(withJSONObject: j) {
                try? out.write(to: URL(fileURLWithPath: Paths.status))
            }
        }
        // Server passwords: same bookmark IDs, new Keychain service.
        for b in BookmarkStore.load() where b.auth == .password {
            if Keychain.get(b.id) == nil, let pw = Keychain.get(b.id, service: oldBundleID + ".sftp") {
                Keychain.set(pw, for: b.id)
            }
        }
        // The old schedule would keep starting the old app – no backup is running (checked above).
        Agent.remove(label: oldLabel, plist: oldPlist)
        try? fm.moveItem(atPath: oldSupport, toPath: oldSupport + " (migrated)")
        try? fm.moveItem(atPath: oldLogs, toPath: oldLogs + " (migrated)")
        return .migrated
    }
}

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
