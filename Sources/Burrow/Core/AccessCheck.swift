import Foundation

/// Can a *scheduled* backup read the local folder? The app itself may read it (e.g. right after the folder was chosen
/// in an open panel) while a run started by launchd may not, so the check runs the executable through launchd, the
/// same way the schedule does. If the folder is protected (Desktop, Documents, Downloads, external or network
/// volumes), macOS asks the user once for that folder – no Full Disk Access needed.
enum AccessCheck {
    static var label: String { AppInfo.agentLabel + ".accesscheck" }
    static var plist: String { Paths.support + "/\(label).plist" }
    static var resultFile: String { Paths.support + "/access-check" }

    /// Folders macOS protects with a per-folder permission; everything else is readable without asking.
    static func isProtected(_ path: String, home: String = Paths.home) -> Bool {
        if path.hasPrefix("/Volumes/") { return true }
        let roots = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { home + "/" + $0 }
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// `Burrow --check-access`: runs under launchd, reads the configured folder, records the answer.
    static func probe() -> Int32 {
        let cfg = AppConfig.load()
        let ok = !cfg.localPath.isEmpty && (try? FileManager.default.contentsOfDirectory(atPath: cfg.localPath)) != nil
        try? (ok ? "ok" : "denied").write(toFile: resultFile, atomically: true, encoding: .utf8)
        return ok ? 0 : 1
    }

    /// Starts the probe through launchd and waits for its answer. Waits long enough for the user to answer the
    /// permission prompt; nil when the probe didn't report back in time.
    static func run(timeout: TimeInterval = 120) -> Bool? {
        guard Install.canSchedule(Install.current) else { return nil }
        Paths.ensure()
        let fm = FileManager.default
        try? fm.removeItem(atPath: resultFile)
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Paths.executable, "--check-access"],
            "RunAtLoad": true,
            "LaunchOnlyOnce": true,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
              (try? data.write(to: URL(fileURLWithPath: plist), options: .atomic)) != nil else { return nil }
        // Only this one-shot job is booted out – never the backup agent.
        runCapture("/bin/launchctl", ["bootout", "\(Agent.domain)/\(label)"])
        runCapture("/bin/launchctl", ["bootstrap", Agent.domain, plist])
        defer {
            runCapture("/bin/launchctl", ["bootout", "\(Agent.domain)/\(label)"])
            try? fm.removeItem(atPath: plist)
        }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let s = try? String(contentsOfFile: resultFile, encoding: .utf8) {
                try? fm.removeItem(atPath: resultFile)
                return s == "ok"
            }
            usleep(250_000)
        }
        return nil
    }
}
