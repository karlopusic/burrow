import Foundation
import Darwin

enum RunResult: String, Codable {
    case running, ok, error, blocked, stopped
}

enum RunTrigger: String, Codable {
    case schedule, manual
}

struct RunRecord: Codable, Identifiable {
    var id = UUID()
    var dryRun: Bool
    var trigger: RunTrigger
    var start: Date
    var end: Date?
    var result: RunResult
    var message = ""
    var uploaded = 0
    var archived = 0
    var modtimeFixed = 0
    var errors = 0
    var bytes = ""
    var localFiles = 0
    var logFile: String
}

struct RunningInfo: Codable {
    var pid: Int32
    var childPid: Int32 = 0
    var start: Date
    var dryRun: Bool
    var logFile: String
}

struct StatusFile: Codable {
    var runs: [RunRecord] = []
    var running: RunningInfo?
    var lastLocalCount: Int?
    /// `AppConfig.backupPair` that `lastLocalCount` was measured for; nil in status files from before 0.4.
    var lastCountPair: String?

    var lastBackup: RunRecord? { runs.first { !$0.dryRun } }
    var lastSuccess: RunRecord? { runs.first { !$0.dryRun && $0.result == .ok } }
    var lastDryRun: RunRecord? { runs.first { $0.dryRun } }
}

func pidAlive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

/// status.json is shared between the GUI and headless runs (launchd); all writes go through an flock.
enum StatusStore {
    static func load() -> StatusFile {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = FileManager.default.contents(atPath: Paths.status),
              var s = try? dec.decode(StatusFile.self, from: d) else { return StatusFile() }
        if let r = s.running, !pidAlive(r.pid) { s.running = nil }
        return s
    }

    @discardableResult
    static func update(_ f: (inout StatusFile) -> Void) -> StatusFile {
        let fd = open(Paths.statusLock, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var s = load()
        f(&s)
        if s.runs.count > 200 { s.runs = Array(s.runs.prefix(200)) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(s) { try? d.write(to: URL(fileURLWithPath: Paths.status), options: .atomic) }
        return s
    }
}
