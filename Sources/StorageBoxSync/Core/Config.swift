import Foundation

enum Frequency: String, Codable, CaseIterable, Identifiable {
    case daily, weekly
    var id: String { rawValue }
}

struct AppConfig: Codable, Equatable {
    // Connection
    var host = ""                       // e.g. u123456.your-storagebox.de
    var port = 23                       // Hetzner Storage Box: 23 = SSH/SFTP with extended commands
    var user = ""                       // e.g. u123456
    var keyFile = Paths.defaultKey

    // What goes where
    var localPath = ""
    var remotePath = ""                 // e.g. /home/Projects
    var versionsPath = "/home/_versions"

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

    var isConnectionConfigured: Bool { !host.isEmpty && !user.isEmpty }
    var isComplete: Bool { isConnectionConfigured && !localPath.isEmpty && !remotePath.isEmpty }

    var remote: String { "\(AppInfo.remoteName):\(remotePath)" }
    var versionsRemote: String { "\(AppInfo.remoteName):\(versionsPath)" }

    /// rclone.conf is derived state – regenerated from config.json so the two can never drift apart.
    func writeRcloneConfig() {
        let conf = """
        [\(AppInfo.remoteName)]
        type = sftp
        host = \(host)
        port = \(port)
        user = \(user)
        key_file = \(keyFile)
        known_hosts_file = \(Paths.knownHosts)
        shell_type = unix
        md5sum_command = md5sum
        sha1sum_command = sha1sum

        """
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
