import Foundation

/// Unit tests for the logic that decides what a backup does. No network, no real data.
/// Run with `scripts/test.sh` (it builds this file together with the app sources, minus the app entry point,
/// and runs it with a throw-away home folder).
@main
enum UnitTests {
    static var failures = 0
    static var passed = 0

    static func check(_ ok: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
        if ok { passed += 1 } else { failures += 1; print("FAIL  \(what)  (\(file):\(line))") }
    }

    static func main() {
        precondition(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil,
                     "run through scripts/test.sh – tests must not touch the real home folder")
        Paths.ensure()
        folderSafety()
        trashSafety()
        archiveNames()
        schedule()
        logParsing()
        keySetup()
        daemonEnvironment()
        installLocation()
        protectedFolders()
        names()
        configDecoding()
        rcloneConfig()
        fileCounting()
        statusStore()
        errorCleaning()
        renameMigration()
        print(failures == 0 ? "ALL \(passed) PASSED" : "\(failures) FAILED, \(passed) passed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: folders

    static func cfg(_ remote: String, _ versions: String) -> AppConfig {
        var c = AppConfig()
        c.host = "example.com"; c.user = "u"; c.localPath = "/tmp/x"
        c.remotePath = remote; c.versionsPath = versions
        return c
    }

    static func folderSafety() {
        check(cfg("/home/Projects", "/home/_versions").folderProblem == nil, "separate folders are fine")
        check(cfg("Projects", "_versions").folderProblem == nil, "relative folders are fine")
        for root in ["/", "/home", ".", "~"] {
            check(cfg(root, "_versions").folderProblem != nil, "server root '\(root)' refused as backup folder")
            check(cfg("Projects", root).folderProblem != nil, "server root '\(root)' refused as versions folder")
        }
        check(cfg("/home/", "_versions").folderProblem != nil, "trailing slash doesn't bypass the root check")
        check(cfg("P", "P").folderProblem != nil, "same folder refused")
        check(cfg("P", "P/_versions").folderProblem != nil, "versions inside backup refused")
        check(cfg("V/P", "V").folderProblem != nil, "backup inside versions refused")
        check(cfg("P", "Px").folderProblem == nil, "name prefix is not nesting")
        check(cfg("/home/Projects", "Projects/_versions").folderProblem != nil, "absolute backup + relative versions inside it refused")
        check(cfg("Projects", "/home/Projects/_v").folderProblem != nil, "relative backup + absolute versions inside it refused")
        check(cfg("/home/_versions/P", "_versions").folderProblem != nil, "backup inside relative versions refused")
        check(cfg("/home/Projects", "_versions").folderProblem == nil, "absolute backup + unrelated relative versions is fine")
        check(cfg("/home/../KARLO", "_v").folderProblem != nil, "parent-directory segment refused")
        check(cfg("./P", "_v").folderProblem != nil, "dot segment refused")
        var moved = cfg("P", "_v"); moved.localPath = "/tmp/other"
        check(cfg("P", "_v").backupPair != moved.backupPair, "another local folder is another backup pair")
        check(cfg("P", "_v").backupPair != cfg("Q", "_v").backupPair, "another server folder is another backup pair")
        check(cfg("P", "_v").backupPair == cfg("P ", "_w").backupPair, "versions folder and whitespace don't change the pair")
        check(cfg("", "").folderProblem == nil && !cfg("", "").isComplete, "empty is incomplete, not wrong")
    }

    // MARK: version folders

    static func trashSafety() {
        func bm(_ path: String, _ trash: String) -> Bookmark {
            var b = Bookmark(); b.path = path; b.trashFolder = trash; return b
        }
        let backup = ["/home/Projects", "/home/_versions"]
        check(bm("", ".burrow-trash").trashProblem(protecting: backup) == nil, "default trash folder is fine")
        check(bm("/", ".burrow-trash").trashProblem(protecting: []) == nil, "default trash under an absolute root start folder is fine")
        for bad in ["", "/", ".", "./", "..", "a/../b", "~", "//"] {
            check(bm("", bad).trashProblem(protecting: []) != nil, "trash folder '\(bad)' refused")
        }
        check(bm("/", "home").trashProblem(protecting: []) != nil, "/home refused as trash")
        check(bm("", "Projects").trashProblem(protecting: backup) != nil, "trash = backup folder (relative vs absolute) refused")
        check(bm("", "_versions/t").trashProblem(protecting: backup) != nil, "trash inside versions refused")
        check(bm("/home", "Projects/.t").trashProblem(protecting: backup) != nil, "trash inside backup via absolute start folder refused")
        check(bm("/home", ".t").trashProblem(protecting: backup) == nil, "sibling trash next to the backup is fine")
        check(bm("", "P").trashProblem(protecting: ["P/sub", "V"]) != nil, "trash as parent of the backup refused")
        check(bm("", "Px").trashProblem(protecting: ["P", "V"]) == nil, "name prefix is not nesting")

        check(RPath.mayOverlap("/home/P/_v", "P"), "relative path may continue an absolute one")
        check(RPath.mayOverlap("P", "/home/P"), "overlap check is symmetric")
        check(!RPath.mayOverlap("/home/Backup", ".burrow-trash"), "unrelated relative and absolute paths don't overlap")
        check(!RPath.mayOverlap("/a/b", "/a/c"), "sibling absolute paths don't overlap")
        check(RPath.mayOverlap("/a", "/a/c"), "absolute parent overlaps")
    }

    static func archiveNames() {
        check(Runner.archiveDate("2026-09-26_210005-1a2b3c4d") != nil, "new stamp parsed")
        check(Runner.archiveDate("2026-09-26_2100") != nil, "pre-0.3 stamp parsed")
        for bad in ["2026-09-26", "Projects", "2026-09-26_2100-x", "2026-09-26_210005-XYZ12345", "../2026-09-26_2100", ""] {
            check(Runner.archiveDate(bad) == nil, "not a version folder: '\(bad)'")
        }
        let stamp = Runner.stampFormatter.string(from: Date()) + "-abcdef12"
        check(Runner.archiveDate(stamp) != nil, "the runner's own stamp is recognized (else pruning would skip it)")

        // pruning: the Mac's clock alone never decides
        let day = 86400.0
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func folder(_ daysAgo: Double) -> String {
            Runner.stampFormatter.string(from: now.addingTimeInterval(-daysAgo * day)) + "-0123abcd"
        }
        let normal = [(folder(200), now.addingTimeInterval(-200 * day)), (folder(100), now.addingTimeInterval(-100 * day)),
                      (folder(10), now.addingTimeInterval(-10 * day)), (folder(0), now)].map { (name: $0.0, serverTime: Optional($0.1)) }
        check(Set(Runner.expiredVersions(normal, now: now, retentionDays: 90)) == [folder(200), folder(100)], "folders past retention are pruned")
        let jumped = now.addingTimeInterval(5 * 365 * day)                   // the Mac thinks it's five years later
        check(Set(Runner.expiredVersions(normal, now: jumped, retentionDays: 90)) == [folder(200), folder(100)],
              "a clock that jumped ahead prunes no more than usual")
        check(Runner.expiredVersions(normal.map { (name: $0.name, serverTime: nil) }, now: now, retentionDays: 90).isEmpty,
              "without server times nothing is pruned")
        let foreign = normal + [(name: "Projects", serverTime: Optional(jumped))]
        check(Set(Runner.expiredVersions(foreign, now: jumped, retentionDays: 90)) == [folder(200), folder(100)],
              "non-stamp folders neither count as server time nor get pruned")
    }

    // MARK: schedule

    static func schedule() {
        var c = cfg("P", "V")
        c.hour = 21; c.minute = 30
        c.frequency = .daily
        check(Agent.calendarInterval(c) == ["Hour": 21, "Minute": 30], "daily has no weekday")
        c.frequency = .weekly
        c.weekday = 7
        check(Agent.calendarInterval(c)["Weekday"] == 0, "Sunday → launchd 0")
        c.weekday = 1
        check(Agent.calendarInterval(c)["Weekday"] == 1, "Monday → launchd 1")

        // The app's "next backup" and launchd's schedule must name the same day for every weekday.
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!   // a Thursday
        for wd in 1...7 {
            c.weekday = wd
            guard let next = c.nextRun(after: start) else { check(false, "weekly next run exists"); continue }
            let calendarWeekday = Calendar.current.component(.weekday, from: next)       // 1 = Sunday
            check(calendarWeekday - 1 == Agent.calendarInterval(c)["Weekday"], "weekday \(wd): app and launchd agree")
            check(Calendar.current.component(.hour, from: next) == 21 && Calendar.current.component(.minute, from: next) == 30,
                  "weekday \(wd): time kept")
            check(next > start && next.timeIntervalSince(start) <= 7 * 86400, "weekday \(wd): within a week")
        }
        c.scheduleEnabled = false
        check(c.nextRun() == nil, "no next run when the schedule is off")

        // catch-up at login (RunAtLoad) vs. scheduled start
        var d = cfg("P", "V"); d.hour = 21; d.minute = 0; d.frequency = .daily
        let g = Calendar.current
        func at(_ day: Int, _ h: Int, _ m: Int = 0, _ s: Int = 0) -> Date {
            g.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m, second: s))!
        }
        let installed = at(1, 10)
        check(Runner.isDue(d, now: at(1, 21, 0, 1), lastAttempt: nil, installed: installed), "first scheduled start runs")
        check(!Runner.isDue(d, now: at(1, 10, 0, 2), lastAttempt: nil, installed: installed), "installing the agent doesn't start a backup")
        check(Runner.isDue(d, now: at(2, 21), lastAttempt: at(1, 21), installed: installed), "daily start runs")
        check(Runner.isDue(d, now: at(3, 8), lastAttempt: at(1, 21), installed: installed), "login after a missed time catches up")
        check(!Runner.isDue(d, now: at(3, 8), lastAttempt: at(2, 21), installed: installed), "login with nothing missed does nothing")
        check(!Runner.isDue(d, now: at(3, 8), lastAttempt: at(2, 23), installed: installed), "a manual run after the time counts")
        check(Runner.isDue(d, now: at(2, 20, 59, 58), lastAttempt: at(1, 21), installed: installed), "a start just before the minute runs")
        check(!Runner.isDue(d, now: at(3, 8), lastAttempt: at(1, 21), installed: at(3, 7)), "settings saved after the missed time: no surprise run")
        d.frequency = .weekly; d.weekday = 5                                           // Friday; 2026-10-02 is a Friday
        check(!Runner.isDue(d, now: at(8, 8), lastAttempt: at(2, 21), installed: installed), "weekly: nothing missed during the week")
        check(Runner.isDue(d, now: at(10, 8), lastAttempt: at(2, 21), installed: installed), "weekly: missed Friday caught up")
        d.scheduleEnabled = false
        check(!Runner.isDue(d, now: at(3, 8), lastAttempt: at(1, 21), installed: installed), "schedule off: never due")
    }

    // MARK: rclone log

    static func tempFile(_ text: String) -> String {
        let p = NSTemporaryDirectory() + "sbs-test-\(UUID().uuidString).log"
        try? text.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    static func logParsing() {
        let run = tempFile("""
        2026/09/26 21:00:01 INFO  : a/new.txt: Copied (new)
        2026/09/26 21:00:02 INFO  : b/changed.txt: Copied (replaced existing)
        2026/09/26 21:00:03 INFO  : b/old.txt: Moved (server-side) to: _versions/2026-09-26_210000-1a2b3c4d/b/old.txt
        2026/09/26 21:00:03 INFO  : c/touched.txt: Updated modification time in destination
        2026/09/26 21:00:04 ERROR : d/bad.txt: Failed to copy: permission denied
        2026/09/26 21:00:04 NOTICE: Obična mapa: Duplicate directory found in destination - ignoring
        2026/09/26 21:00:05 INFO  :
        Transferred:   	    1.500 MiB / 1.500 MiB, 100%, 300 KiB/s, ETA 0s
        Transferred:            2 / 2, 100%
        """)
        let s = LogParser.summarize(run, dryRun: false)
        check(s.uploaded == 2, "uploads counted (new + replaced)")
        check(s.archived == 1, "archived counted")
        check(s.modtime == 1, "modtime fixes counted")
        check(s.errors == 1 && s.lastError.contains("permission denied"), "errors counted")
        check(s.duplicates == ["Obična mapa"], "duplicate names found")
        check(s.bytes == "1.500 MiB / 1.500 MiB", "transferred bytes")

        let dry = tempFile("""
        2026/09/26 21:00:01 NOTICE: a/new file.txt: Skipped copy as --dry-run is set (size 1.2Mi)
        2026/09/26 21:00:02 NOTICE: b/gone.txt: Skipped move as --dry-run is set (size 3)
        2026/09/26 21:00:02 NOTICE: b/also: gone.txt: Skipped delete as --dry-run is set (size 10)
        2026/09/26 21:00:03 NOTICE: c/t.txt: Skipped update modification time as --dry-run is set (size 1)
        """)
        let d = LogParser.summarize(dry, dryRun: true)
        check(d.uploaded == 1 && d.archived == 2 && d.modtime == 1, "dry-run counts")
        let items = LogParser.preview(dry)
        check(items.count == 3, "preview lists uploads and archives only")
        check(items.first?.path == "a/new file.txt" && items.first?.size == "1.2Mi", "preview path and size")
        check(items.last?.path == "b/also: gone.txt", "preview path with ': ' in the name")

        let live = tempFile("""
        Transferred:   	  120 MiB / 1 GiB, 12%, 10 MiB/s, ETA 1m30s
        Checks:               100 / 200, 50%
        Transferred:            3 / 10, 30%
        Elapsed time:        12.0s
        Transferring:
         *                                   big.bin: 40% /300Mi, 10Mi/s, 18s
        """)
        let p = LogParser.progress(live)
        check(abs((p.percent ?? 0) - 0.12) < 0.0001, "progress percent")
        check(p.checks == "100 / 200, 50%" && p.transfers == "3 / 10, 30%" && p.elapsed == "12.0s", "progress lines")
        check(p.current.count == 1 && p.current[0].hasPrefix("big.bin"), "files in flight")
        check(LogParser.summarize("/nonexistent", dryRun: false).uploaded == 0, "missing log is empty, not a crash")
        for f in [run, dry, live] { try? FileManager.default.removeItem(atPath: f) }
    }

    // MARK: key setup

    static func keySetup() {
        check(KeySetup.existingKeys((0, "ssh-ed25519 AAA other\n", "")) == "ssh-ed25519 AAA other\n", "existing keys kept")
        check(KeySetup.existingKeys((3, "", "directory not found")) == "", "no .ssh folder → empty")
        check(KeySetup.existingKeys((4, "", "object not found")) == "", "no authorized_keys → empty")
        check(KeySetup.existingKeys((1, "", "Failed to cat: object not found")) == "", "not found by message → empty")
        // Everything else must stop the setup; treating it as empty would replace the user's keys.
        check(KeySetup.existingKeys((1, "", "Failed to cat: permission denied")) == nil, "permission error stops")
        check(KeySetup.existingKeys((5, "", "i/o timeout")) == nil, "timeout stops")
        check(KeySetup.existingKeys((-1, "", "launch failed")) == nil, "launch failure stops")
        let core = "ssh-ed25519 AAA"
        check(KeySetup.keyAction(existing: (0, "ssh-ed25519 BBB other\n", ""), publicKeyCore: core) == .manual,
              "existing key list is never rewritten")
        check(KeySetup.keyAction(existing: (0, "ssh-ed25519 AAA ours\n", ""), publicKeyCore: core) == .alreadyInstalled,
              "installed key needs no write")
        check(KeySetup.keyAction(existing: (0, "ssh-ed25519 BBB ssh-ed25519 AAA\n", ""), publicKeyCore: core) == .manual,
              "key text inside another key's comment is not an installed key")
        check(KeySetup.keyAction(existing: (4, "", "object not found"), publicKeyCore: core) == .create,
              "missing key file may be created")
    }

    // MARK: rclone daemon

    static func daemonEnvironment() {
        let env = RcloneDaemon.environment(user: "u1", pass: "p1",
                                           base: ["PATH": "/usr/bin", "RCLONE_CONFIG_PASS": "x", "RCLONE_RC_NO_AUTH": "true"])
        check(env["RCLONE_RC_USER"] == "u1" && env["RCLONE_RC_PASS"] == "p1", "credentials passed via environment")
        check(env["RCLONE_RC_NO_AUTH"] == nil && env["RCLONE_CONFIG_PASS"] == nil, "inherited RCLONE_* settings dropped")
        check(env["PATH"] == "/usr/bin", "other environment kept")
    }

    // MARK: install location

    static func installLocation() {
        let home = "/Users/test"
        check(Install.location(of: "/Applications/Burrow.app", home: home) == .applications, "/Applications")
        check(Install.location(of: home + "/Applications/Burrow.app", home: home) == .applications, "~/Applications")
        check(Install.location(of: "/private/var/folders/xy/T/AppTranslocation/1234/d/Burrow.app", home: home) == .translocated,
              "translocated")
        check(Install.location(of: "/Volumes/Burrow/Burrow.app", home: home) == .diskImage, "disk image")
        check(Install.location(of: home + "/Tools/Burrow.app", home: home) == .elsewhere, "elsewhere")
        check(Install.location(of: "/Applications/Utilities/Burrow.app", home: home) == .elsewhere, "subfolder of Applications")
        check(!Install.canSchedule(.translocated) && !Install.canSchedule(.diskImage), "no schedule from temporary paths")
        check(Install.canSchedule(.applications) && Install.canSchedule(.elsewhere), "schedule from stable paths")
    }

    static func protectedFolders() {
        let home = "/Users/test"
        for p in ["/Desktop", "/Desktop/Projects", "/Documents/a/b", "/Downloads/x", "/Library/Mobile Documents/com~apple~CloudDocs/x"] {
            check(AccessCheck.isProtected(home + p, home: home), "protected: \(p)")
        }
        check(AccessCheck.isProtected("/Volumes/Disk/Work", home: home), "protected: external volume")
        for p in ["/Projects", "/DesktopStuff", "/Pictures/x"] {
            check(!AccessCheck.isProtected(home + p, home: home), "not protected: \(p)")
        }
    }

    // MARK: names

    static func names() {
        let nfd = "Izvjes\u{030C}taj.txt", nfc = "Izvještaj.txt"
        check(!nfd.unicodeScalars.elementsEqual(nfc.unicodeScalars), "fixture really differs in scalars")
        check(nfd.nfc.unicodeScalars.elementsEqual(nfc.unicodeScalars), "nfc converts")
        let unique = RPath.uniqueName(nfd, taken: [nfc])
        check(unique.unicodeScalars.elementsEqual("Izvještaj 2.txt".unicodeScalars), "NFD name conflicts with its NFC spelling")
        check(RPath.uniqueName("Folder", taken: ["Folder", "Folder 2"]) == "Folder 3", "unique folder name")
        check(RPath.uniqueName("a.tar.gz", taken: ["a.tar.gz"]) == "a.tar 2.gz", "unique name keeps last extension")
        check(RPath.uniqueName("free.txt", taken: ["other"]) == "free.txt", "free name unchanged")
        check(RPath.uniqueName("report.pdf", taken: ["Report.pdf"]) == "report 2.pdf", "names differing only in case conflict")
        check(RPath.uniqueName("a.txt", taken: ["a 2.txt", "A.TXT"]) == "a 3.txt", "unique name skips case variants")
        check(RPath.isTaken("ŠKOLA", ["s\u{030C}kola"]), "case + NFD variant counts as taken")
        check(!RPath.isTaken("Report.pdf", ["Report.pdfx"]), "different name is free")
        check(RPath.join("a/", "/b", "c") == "a/b/c" && RPath.join("", "x") == "x", "join")
        check(RPath.parent("a/b/c") == "a/b" && RPath.parent("a") == "", "parent")
        check(RPath.name("a/b/c.txt") == "c.txt", "name")
    }

    // MARK: config

    static func configDecoding() {
        let old = #"{"host":"u1.your-storagebox.de","user":"u1","localPath":"/x","remotePath":"/home/P","versionsPath":"/home/_v"}"#
        let c = try? JSONDecoder().decode(AppConfig.self, from: Data(old.utf8))
        check(c != nil, "old config decodes")
        check(c?.port == 22 && c?.retentionDays == 90 && c?.maxDelete == 300, "missing keys get defaults")
        check(c?.remoteShell == true, "pre-0.3 Storage Box config keeps remote shell")
        let other = try? JSONDecoder().decode(AppConfig.self, from: Data(#"{"host":"sftp.example.com"}"#.utf8))
        check(other?.remoteShell == false, "other servers default to no remote shell")
        check((try? JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))) != nil, "empty config decodes")
    }

    static func rcloneConfig() {
        var c = cfg("P", "V")
        c.host = "evil.example.com\nkey_file = /etc/passwd"
        c.user = "u\r\nshell_type = unix"
        c.writeRcloneConfig()
        let text = (try? String(contentsOfFile: Paths.rcloneConf, encoding: .utf8)) ?? ""
        let keys = text.split(separator: "\n").compactMap { $0.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) }
        check(keys.filter { $0 == "key_file" }.count == 1 && keys.filter { $0 == "shell_type" }.count == 1,
              "line breaks in fields can't add rclone options")
        let perms = (try? FileManager.default.attributesOfItem(atPath: Paths.rcloneConf)[.posixPermissions] as? Int) ?? 0
        check(perms == 0o600, "rclone.conf is private")
    }

    // MARK: file count

    static func fileCounting() {
        let dir = NSTemporaryDirectory() + "sbs-count-\(UUID().uuidString)"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        for f in ["a.txt", "sub/b.txt", ".DS_Store", "sub/._c", "doc.idlk", "~$report.docx", "x.1a2b3c4d.partial"] {
            fm.createFile(atPath: dir + "/" + f, contents: Data("x".utf8))
        }
        let n = Runner.countFiles(dir, excludes: AppConfig().excludes + Runner.builtinExcludes)
        check(n == 2, "count skips excluded and temp files (got \(n))")
        check(Runner.countFiles(dir + "/missing", excludes: []) == -1, "unreadable folder reports -1")
        let denied = dir + "/denied"
        try? fm.createDirectory(atPath: denied, withIntermediateDirectories: true)
        fm.createFile(atPath: denied + "/hidden.txt", contents: Data("x".utf8))
        _ = chmod(denied, 0o000)
        check(Runner.countFiles(dir, excludes: []) == -1, "nested read error is not treated as a complete source")
        _ = chmod(denied, 0o700)
        try? fm.removeItem(atPath: dir)
    }

    // MARK: status

    static func statusStore() {
        try? FileManager.default.removeItem(atPath: Paths.status)
        StatusStore.update { s in
            for i in 0..<250 {
                s.runs.append(RunRecord(dryRun: false, trigger: .manual, start: Date(), result: i == 0 ? .ok : .error, logFile: "l"))
            }
            s.running = RunningInfo(pid: 999_999, start: Date(), dryRun: false, logFile: "l")   // not a live pid
        }
        let s = StatusStore.load()
        check(s.runs.count == 200, "history capped at 200")
        check(s.running == nil, "a dead run is not reported as running")
        check(s.lastSuccess?.result == .ok, "last success found")
    }

    // MARK: rename StorageBox Sync → Burrow

    static func renameMigration() {
        let fm = FileManager.default
        for p in [Paths.config, Paths.status, Paths.support + "/bookmarks.json"] { try? fm.removeItem(atPath: p) }
        let old = RenameMigration.oldSupport, oldLogs = RenameMigration.oldLogs
        try? fm.createDirectory(atPath: old, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: oldLogs, withIntermediateDirectories: true)
        try? #"{"host":"sftp.example.com","user":"u","localPath":"/x","remotePath":"P","versionsPath":"V","hour":5}"#
            .write(toFile: old + "/config.json", atomically: true, encoding: .utf8)
        try? #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"S","host":"h","port":22,"user":"u","auth":"key","keyFile":"/k","path":"","trashFolder":".sbs-trash"}]"#
            .write(toFile: old + "/bookmarks.json", atomically: true, encoding: .utf8)
        let oldLog = oldLogs + "/2026-09-26_210000-1a2b3c4d.log"
        try? "log".write(toFile: oldLog, atomically: true, encoding: .utf8)

        // A backup of the old app is still running: nothing may happen yet.
        let running = #"{"runs":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","dryRun":false,"trigger":"schedule","start":"2026-09-26T19:00:00Z","result":"ok","message":"","uploaded":1,"archived":0,"modtimeFixed":0,"errors":0,"bytes":"","localFiles":1,"logFile":"\#(oldLog)"}],"running":{"pid":\#(getpid()),"childPid":0,"start":"2026-09-26T19:00:00Z","dryRun":false,"logFile":"l"}}"#
        try? running.write(toFile: old + "/status.json", atomically: true, encoding: .utf8)
        check(RenameMigration.runIfNeeded() == .waitingForLegacyRun, "migration waits for a running old backup")
        check(!fm.fileExists(atPath: Paths.config), "nothing migrated while the old backup runs")

        try? running.replacingOccurrences(of: #""running":{"pid":\#(getpid())"#, with: #""running":{"pid":999999"#)
            .write(toFile: old + "/status.json", atomically: true, encoding: .utf8)
        check(RenameMigration.runIfNeeded(installLocation: .diskImage) == .waitingForInstall,
              "opening the DMG keeps the old installation and schedule")
        check(!fm.fileExists(atPath: Paths.config) && fm.fileExists(atPath: old + "/config.json"),
              "temporary launch makes no migration changes")
        check(RenameMigration.runIfNeeded(activateSchedule: { _ in false }, retireOldSchedule: { true }) == .failed,
              "failed new schedule stops migration")
        check(!fm.fileExists(atPath: Paths.config) && fm.fileExists(atPath: old + "/config.json"),
              "failed schedule leaves migration retryable")
        try? "{invalid".write(toFile: old + "/status.json", atomically: true, encoding: .utf8)
        check(RenameMigration.runIfNeeded(activateSchedule: { _ in true }, retireOldSchedule: { true }) == .failed,
              "corrupt old history does not retire the old schedule")
        check(!fm.fileExists(atPath: Paths.config), "failed history import remains retryable")
        try? running.replacingOccurrences(of: #""running":{"pid":\#(getpid())"#, with: #""running":{"pid":999999"#)
            .write(toFile: old + "/status.json", atomically: true, encoding: .utf8)
        UserDefaults(suiteName: RenameMigration.oldBundleID)?.set("hr", forKey: "test.migratedKey")
        RenameMigration.migrateDefaults()
        check(UserDefaults.standard.string(forKey: "test.migratedKey") == "hr", "preferences migrated")
        check(RenameMigration.runIfNeeded(activateSchedule: { _ in true }, retireOldSchedule: { true }) == .migrated,
              "migration runs when idle and the new schedule is available")
        check(AppConfig.load().host == "sftp.example.com" && AppConfig.load().hour == 5, "config migrated")
        check(BookmarkStore.load().first?.trashFolder == ".sbs-trash", "bookmarks migrated unchanged")
        check(fm.fileExists(atPath: Paths.logs + "/2026-09-26_210000-1a2b3c4d.log"), "logs copied")
        let s = StatusStore.load()
        check(s.runs.first?.logFile == Paths.logs + "/2026-09-26_210000-1a2b3c4d.log", "history points at the new logs")
        check(fm.fileExists(atPath: old + " (migrated)") && !fm.fileExists(atPath: old), "old folder kept as (migrated)")
        check(RenameMigration.runIfNeeded() == .none, "migration runs only once")
        UserDefaults.standard.removeObject(forKey: "test.migratedKey")
    }

    static func errorCleaning() {
        let msg = #"couldn't list ":sftp,host="h",user="u",pass="secret":dir": permission denied"#
        let clean = RcloneDaemon.clean(msg)
        check(!clean.contains("secret") && clean.contains("permission denied"), "connection string removed from errors")
    }
}
