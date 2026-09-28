import Foundation

/// The per-user LaunchAgent that runs `Burrow --run` on schedule, even when the app is closed.
enum Agent {
    static var domain: String { "gui/\(getuid())" }

    static func install(_ cfg: AppConfig) {
        // From the DMG or a translocated path the agent would point at a path that vanishes. Leave any existing
        // agent (e.g. of the copy in Applications) untouched instead.
        guard Install.canSchedule(Install.current) else { return }
        var plist: [String: Any] = [
            "Label": AppInfo.agentLabel,
            "ProgramArguments": [Paths.executable, "--run", "--trigger=schedule"],
            "RunAtLoad": false,
            "StandardOutPath": Paths.logs + "/agent.log",
            "StandardErrorPath": Paths.logs + "/agent.log",
        ]
        if cfg.scheduleEnabled && cfg.isComplete { plist["StartCalendarInterval"] = calendarInterval(cfg) }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        let loaded = runCapture("/bin/launchctl", ["print", "\(domain)/\(AppInfo.agentLabel)"]).code == 0
        if FileManager.default.contents(atPath: Paths.agentPlist) == data && loaded { return }
        try? data.write(to: URL(fileURLWithPath: Paths.agentPlist), options: .atomic)
        remove(label: AppInfo.agentLabel, plist: nil)
        runCapture("/bin/launchctl", ["bootstrap", domain, Paths.agentPlist])
    }

    /// launchd counts weekdays 0 = Sunday … 6 = Saturday; the config uses 1 = Monday … 7 = Sunday.
    static func calendarInterval(_ cfg: AppConfig) -> [String: Int] {
        var cal: [String: Int] = ["Hour": cfg.hour, "Minute": cfg.minute]
        if cfg.frequency == .weekly { cal["Weekday"] = cfg.weekday % 7 }
        return cal
    }

    /// Note: bootout kills a job that launchd is currently running – callers must check for an active run first.
    static func remove(label: String, plist: String?) {
        runCapture("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        if let plist { try? FileManager.default.removeItem(atPath: plist) }
    }
}
