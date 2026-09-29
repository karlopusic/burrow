import Foundation

/// The per-user LaunchAgent that runs `Burrow --run` on schedule, even when the app is closed.
enum Agent {
    static var domain: String { "gui/\(getuid())" }

    @discardableResult
    static func install(_ cfg: AppConfig) -> Bool {
        // From the DMG or a translocated path the agent would point at a path that vanishes. Leave any existing
        // agent (e.g. of the copy in Applications) untouched instead.
        guard Install.canSchedule(Install.current) else { return false }
        var plist: [String: Any] = [
            "Label": AppInfo.agentLabel,
            "ProgramArguments": [Paths.executable, "--run", "--trigger=schedule"],
            "RunAtLoad": false,
            "StandardOutPath": Paths.logs + "/agent.log",
            "StandardErrorPath": Paths.logs + "/agent.log",
        ]
        if cfg.scheduleEnabled && cfg.isComplete { plist["StartCalendarInterval"] = calendarInterval(cfg) }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return false }
        let loaded = runCapture("/bin/launchctl", ["print", "\(domain)/\(AppInfo.agentLabel)"]).code == 0
        if FileManager.default.contents(atPath: Paths.agentPlist) == data && loaded { return true }
        guard (try? data.write(to: URL(fileURLWithPath: Paths.agentPlist), options: .atomic)) != nil else { return false }
        guard remove(label: AppInfo.agentLabel, plist: nil) else { return false }
        guard runCapture("/bin/launchctl", ["bootstrap", domain, Paths.agentPlist]).code == 0 else { return false }
        return runCapture("/bin/launchctl", ["print", "\(domain)/\(AppInfo.agentLabel)"]).code == 0
    }

    /// launchd counts weekdays 0 = Sunday … 6 = Saturday; the config uses 1 = Monday … 7 = Sunday.
    static func calendarInterval(_ cfg: AppConfig) -> [String: Int] {
        var cal: [String: Int] = ["Hour": cfg.hour, "Minute": cfg.minute]
        if cfg.frequency == .weekly { cal["Weekday"] = cfg.weekday % 7 }
        return cal
    }

    /// Note: bootout kills a job that launchd is currently running – callers must check for an active run first.
    @discardableResult
    static func remove(label: String, plist: String?) -> Bool {
        runCapture("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        guard runCapture("/bin/launchctl", ["print", "\(domain)/\(label)"]).code != 0 else { return false }
        if let plist, FileManager.default.fileExists(atPath: plist) {
            do { try FileManager.default.removeItem(atPath: plist) } catch { return false }
        }
        return true
    }
}
