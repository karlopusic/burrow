import Foundation

/// The per-user LaunchAgent that runs `StorageBoxSync --run` on schedule, even when the app is closed.
enum Agent {
    static var domain: String { "gui/\(getuid())" }

    static func install(_ cfg: AppConfig) {
        var plist: [String: Any] = [
            "Label": AppInfo.agentLabel,
            "ProgramArguments": [Paths.executable, "--run", "--trigger=schedule"],
            "RunAtLoad": false,
            "StandardOutPath": Paths.logs + "/agent.log",
            "StandardErrorPath": Paths.logs + "/agent.log",
        ]
        if cfg.scheduleEnabled && cfg.isComplete {
            var cal: [String: Int] = ["Hour": cfg.hour, "Minute": cfg.minute]
            if cfg.frequency == .weekly { cal["Weekday"] = cfg.weekday % 7 } // launchd: 0 = Sunday, 1 = Monday
            plist["StartCalendarInterval"] = cal
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        let loaded = runCapture("/bin/launchctl", ["print", "\(domain)/\(AppInfo.agentLabel)"]).code == 0
        if FileManager.default.contents(atPath: Paths.agentPlist) == data && loaded { return }
        try? data.write(to: URL(fileURLWithPath: Paths.agentPlist), options: .atomic)
        remove(label: AppInfo.agentLabel, plist: nil)
        runCapture("/bin/launchctl", ["bootstrap", domain, Paths.agentPlist])
    }

    /// Note: bootout kills a job that launchd is currently running – callers must check for an active run first.
    static func remove(label: String, plist: String?) {
        runCapture("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        if let plist { try? FileManager.default.removeItem(atPath: plist) }
    }
}
