import Foundation
import Darwin

/// Headless backup / dry-run. Invoked as `StorageBoxSync --run` (launchd or GUI) or `--dry-run`.
///
/// Safety model:
///  - `rclone sync --backup-dir`: files changed or deleted locally are moved into a dated folder under
///    `versionsPath` instead of being overwritten/deleted on the box.
///  - Blocks the run if the local file count dropped sharply since the last good backup
///    (unmounted disk, accidental delete, ransomware) until the user confirms with "Run anyway".
///  - `--max-delete` caps how many files a single run may archive.
enum Runner {
    /// rclone uploads to "<name>.<8 hex>.partial" and renames when done; a killed run can leave these behind.
    static let partialGlob = "*.[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].partial"
    /// Lock/temp files of open documents (InDesign, Office, LibreOffice): they vanish mid-run and are never worth keeping.
    static let builtinExcludes = [partialGlob, "*.idlk", "~$*", ".~lock.*#"]

    static func main(args: [String]) -> Int32 {
        Paths.ensure()
        let dryRun = args.contains("--dry-run")
        let trigger: RunTrigger = args.contains("--trigger=schedule") ? .schedule : .manual
        let cfg = AppConfig.load()
        let fm = FileManager.default

        let force = fm.fileExists(atPath: Paths.forceFlag)
        try? fm.removeItem(atPath: Paths.stopFlag)

        // A unique folder per run: two manual/scheduled runs may start in the same minute.
        let stamp = stampFormatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(8))
        let logFile = Paths.logs + "/\(stamp)\(dryRun ? "_preview" : "").log"
        var rec = RunRecord(dryRun: dryRun, trigger: trigger, start: Date(), result: .running, logFile: logFile)

        var alreadyRunning = false
        StatusStore.update { s in
            if let r = s.running, pidAlive(r.pid), r.pid != getpid() { alreadyRunning = true; return }
            s.running = RunningInfo(pid: getpid(), start: rec.start, dryRun: dryRun, logFile: logFile)
        }
        if alreadyRunning {
            if trigger == .schedule { notify(L("Skipped"), L("A backup is already running.")) }
            return 0
        }

        func finish(_ result: RunResult, _ message: String) -> Int32 {
            rec.end = Date(); rec.result = result; rec.message = message
            let r = rec
            StatusStore.update { s in
                s.running = nil
                s.runs.insert(r, at: 0)
                if !r.dryRun && r.result == .ok { s.lastLocalCount = r.localFiles }
            }
            pruneLogs()
            switch result {
            case .ok:
                if dryRun {
                    notify(L("Preview finished"), L("To upload: %ld, to archive: %ld", r.uploaded, r.archived))
                } else {
                    notify(L("Backup finished"), L("Uploaded: %ld, archived: %ld", r.uploaded, r.archived))
                }
            case .stopped: notify(L("Stopped"), message)
            default: notify(dryRun ? L("Preview failed") : L("Backup failed"), message)
            }
            return result == .ok ? 0 : 1
        }

        guard cfg.isComplete else { return finish(.error, L("Setup is not complete. Open Settings.")) }
        if let problem = cfg.folderProblem { return finish(.blocked, problem) }
        cfg.writeRcloneConfig()

        // --- source sanity checks ---
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cfg.localPath, isDirectory: &isDir), isDir.boolValue else {
            return finish(.error, L("Local folder not found: %@", cfg.localPath))
        }
        let count = countFiles(cfg.localPath, excludes: cfg.excludes + builtinExcludes)
        rec.localFiles = count
        guard count >= 0 else { return finish(.error, L("No access to the local folder. Grant Full Disk Access.")) }
        guard count > 0 else { return finish(.blocked, L("The local folder is empty – backup blocked.")) }
        if !dryRun, let last = StatusStore.load().lastLocalCount,
           Double(count) < Double(last) * cfg.minFileRatio, !force {
            return finish(.blocked, L("The local folder has %ld files, last time it had %ld. Backup blocked for safety – use “Run anyway” if this is intended.", count, last))
        }
        if force && !dryRun { try? fm.removeItem(atPath: Paths.forceFlag) }

        // --- rclone sync ---
        var a = ["--config", Paths.rcloneConf, "sync", cfg.localPath, cfg.remote,
                 "--backup-dir", "\(cfg.versionsRemote)/\(stamp)",
                 "--max-delete", String(cfg.maxDelete),
                 "--checkers", "8", "--transfers", "4",
                 "--local-unicode-normalization",          // upload names in NFC, never a second NFD spelling
                 "--retries", "3", "--low-level-retries", "10",
                 "--stats", "5s", "--log-level", "INFO", "--log-file", logFile]
        for x in cfg.excludes + builtinExcludes { a += ["--exclude", x] }
        if dryRun { a.append("--dry-run") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.rclone)
        p.arguments = a
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return finish(.error, L("Could not start rclone: %@", error.localizedDescription)) }
        let child = p.processIdentifier
        StatusStore.update { $0.running?.childPid = child }
        // Prevent idle sleep for as long as rclone runs.
        let caf = Process()
        caf.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caf.arguments = ["-i", "-w", String(child)]
        try? caf.run()
        p.waitUntilExit()

        let sum = LogParser.summarize(logFile, dryRun: dryRun)
        rec.uploaded = sum.uploaded; rec.archived = sum.archived; rec.modtimeFixed = sum.modtime
        rec.errors = sum.errors; rec.bytes = sum.bytes

        if !dryRun && p.terminationStatus != 0 { removePartials(cfg) }
        if fm.fileExists(atPath: Paths.stopFlag) {
            try? fm.removeItem(atPath: Paths.stopFlag)
            return finish(.stopped, L("Stopped by user. The next run continues where this one left off."))
        }
        guard p.terminationStatus == 0 else {
            let why = sum.lastError.components(separatedBy: "ERROR : ").last ?? "rclone exit \(p.terminationStatus)"
            return finish(.error, L("Errors (%ld): %@", sum.errors, why))
        }
        if !dryRun { pruneVersions(cfg) }
        let done = dryRun ? L("Preview finished.") : L("Backup successful.")
        if let first = sum.duplicates.first {
            return finish(.ok, done + " " + L("Names that exist twice on the server with differently encoded letters: %ld (e.g. “%@”). One copy of each is skipped – see the log.", sum.duplicates.count, first))
        }
        return finish(.ok, done)
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HHmmss"; return f
    }()

    /// Both pre-0.3 minute folders and new unique second folders are readable.
    static func archiveDate(_ name: String) -> Date? {
        if name.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}-[0-9A-Fa-f]{8}$"#,
                      options: .regularExpression) != nil {
            return stampFormatter.date(from: String(name.prefix(17)))
        }
        guard name.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$"#,
                         options: .regularExpression) != nil else { return nil }
        let old = DateFormatter()
        old.locale = Locale(identifier: "en_US_POSIX")
        old.dateFormat = "yyyy-MM-dd_HHmm"
        return old.date(from: name)
    }

    /// Regular files that rclone will consider. Returns -1 when the folder can't be read (missing TCC permission).
    static func countFiles(_ path: String, excludes: [String]) -> Int {
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: path)) != nil, let e = fm.enumerator(atPath: path) else { return -1 }
        let names = excludes.filter { !$0.contains("/") }
        var n = 0
        while let rel = e.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            if names.contains(where: { fnmatch($0, name, 0) == 0 }) { continue }
            if (e.fileAttributes?[.type] as? FileAttributeType) == .typeRegular { n += 1 }
        }
        return n
    }

    /// Deletes dated version folders older than the retention window. Only folders named like a stamp are touched.
    static func pruneVersions(_ cfg: AppConfig) {
        let r = rclone(["lsf", "--dirs-only", cfg.versionsRemote])
        guard r.code == 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(cfg.retentionDays) * 86400)
        for line in r.out.split(separator: "\n") {
            let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let d = archiveDate(name), d < cutoff else { continue }
            rclone(["purge", "\(cfg.versionsRemote)/\(name)"])
        }
    }

    /// Deletes only rclone's own interrupted-upload temp files, never user data.
    static func removePartials(_ cfg: AppConfig) {
        rclone(["delete", cfg.remote, "--include", partialGlob])
    }

    static func pruneLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Paths.logs) else { return }
        let logs = files.filter { $0.hasSuffix(".log") && $0 != "agent.log" }.sorted(by: >)
        for f in logs.dropFirst(90) { try? fm.removeItem(atPath: Paths.logs + "/" + f) }
    }
}
