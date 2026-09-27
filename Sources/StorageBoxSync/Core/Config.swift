import Foundation

enum Frequency: String, Codable, CaseIterable, Identifiable {
    case daily, weekly
    var id: String { rawValue }
}

struct AppConfig: Codable, Equatable {
    // Connection
    var host = ""                       // e.g. u123456.your-storagebox.de
    var port = 22                       // Standard SFTP; the Hetzner preset uses port 23
    var user = ""                       // e.g. u123456
    var keyFile = Paths.defaultKey
    var backupBookmarkID: UUID?         // bookmark whose connection the backup uses
    var remoteShell = false              // opt in for hosts that permit SSH shell commands

    // What goes where
    var localPath = ""
    var remotePath = ""                 // e.g. /home/Projects
    var versionsPath = "_versions"

    // Schedule
    var scheduleEnabled = true
    var frequency: Frequency = .daily
    var weekday = 7                     // 1 = Monday … 7 = Sunday
    var hour = 21
    var minute = 0

    // Safety
    var retentionDays = 90
    var maxDelete = 300
    var minFileRatio = 0.8              // block a run if >20% of local files vanished since the last good backup
    var excludes = [".DS_Store", "._*", ".Spotlight-V100/**", ".Trashes/**", ".fseventsd/**", ".TemporaryItems/**"]

    init() {}

    // Tolerant decoding: configs written by older versions simply lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? d.user
        keyFile = try c.decodeIfPresent(String.self, forKey: .keyFile) ?? d.keyFile
        backupBookmarkID = try c.decodeIfPresent(UUID.self, forKey: .backupBookmarkID)
        remoteShell = try c.decodeIfPresent(Bool.self, forKey: .remoteShell)
            ?? host.hasSuffix(".your-storagebox.de")
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath) ?? d.localPath
        remotePath = try c.decodeIfPresent(String.self, forKey: .remotePath) ?? d.remotePath
        versionsPath = try c.decodeIfPresent(String.self, forKey: .versionsPath) ?? d.versionsPath
        scheduleEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? d.scheduleEnabled
        frequency = try c.decodeIfPresent(Frequency.self, forKey: .frequency) ?? d.frequency
        weekday = try c.decodeIfPresent(Int.self, forKey: .weekday) ?? d.weekday
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? d.hour
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? d.minute
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        maxDelete = try c.decodeIfPresent(Int.self, forKey: .maxDelete) ?? d.maxDelete
        minFileRatio = try c.decodeIfPresent(Double.self, forKey: .minFileRatio) ?? d.minFileRatio
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? d.excludes
    }

    static func load() -> AppConfig {
        guard let d = FileManager.default.contents(atPath: Paths.config),
              let c = try? JSONDecoder().decode(AppConfig.self, from: d) else { return AppConfig() }
        return c
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: URL(fileURLWithPath: Paths.config), options: .atomic) }
        writeRcloneConfig()
    }

    mutating func use(_ b: Bookmark) {
        backupBookmarkID = b.id
        host = b.host; port = b.port; user = b.user; keyFile = b.keyFile
        remoteShell = b.usesRemoteShell
    }

    var isConnectionConfigured: Bool { !host.isEmpty && !user.isEmpty }
    var isComplete: Bool {
        isConnectionConfigured && !localPath.isEmpty && !remotePath.isEmpty
            && !versionsPath.isEmpty && folderProblem == nil
    }

    /// Folder choices that would make a backup dangerous or impossible; nil when they're fine.
    var folderProblem: String? {
        func norm(_ p: String) -> String {
            let t = p.trimmingCharacters(in: .whitespaces)
            return t.count > 1 && t.hasSuffix("/") ? String(t.dropLast()) : t
        }
        let remote = norm(remotePath), versions = norm(versionsPath)
        if remote.isEmpty || versions.isEmpty { return nil }            // incomplete, not wrong
        if [remote, versions].contains(where: { path in
            path.split(separator: "/").contains { $0 == "." || $0 == ".." }
        }) { return L("Folder paths cannot contain dot or parent-directory segments.") }
        if ["/", "/home", ".", "~"].contains(remote) {
            return L("Choose a dedicated backup subfolder on the server. The server root cannot be a backup folder.")
        }
        if ["/", "/home", ".", "~"].contains(versions) {
            return L("Choose a dedicated versions subfolder on the server.")
        }
        if remote == versions || versions.hasPrefix(remote + "/") || remote.hasPrefix(versions + "/") {
            return L("The versions folder must be outside the backup folder.")
        }
        return nil
    }

    var remote: String { "\(AppInfo.remoteName):\(remotePath)" }
    var versionsRemote: String { "\(AppInfo.remoteName):\(versionsPath)" }

    /// rclone.conf is derived state – regenerated from config.json so the two can never drift apart.
    func writeRcloneConfig() {
        var conf = """
        [\(AppInfo.remoteName)]
        type = sftp
        host = \(host)
        port = \(port)
        user = \(user)
        key_file = \(keyFile)
        known_hosts_file = \(Paths.knownHosts)
        shell_type = \(remoteShell ? "unix" : "none")

        """
        if remoteShell { conf += "md5sum_command = md5sum\nsha1sum_command = sha1sum\n" }
        FileManager.default.createFile(atPath: Paths.rcloneConf, contents: Data(conf.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    func nextRun(after date: Date = Date()) -> Date? {
        guard scheduleEnabled else { return nil }
        var comps = DateComponents(); comps.hour = hour; comps.minute = minute
        if frequency == .weekly { comps.weekday = weekday == 7 ? 1 : weekday + 1 } // Calendar: 1 = Sunday
        return Calendar.current.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
    }
}
