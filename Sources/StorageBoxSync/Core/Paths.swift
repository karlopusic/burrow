import Foundation

enum AppInfo {
    static let name = "StorageBox Sync"
    static let bundleID = "hr.push.storageboxsync"
    static let agentLabel = bundleID
    static let remoteName = "box"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let support = home + "/Library/Application Support/\(AppInfo.name)"
    static let logs = home + "/Library/Logs/\(AppInfo.name)"
    static let config = support + "/config.json"
    static let status = support + "/status.json"
    static let statusLock = support + "/status.lock"
    static let rcloneConf = support + "/rclone.conf"
    static let forceFlag = support + "/force-next"
    static let stopFlag = support + "/stop-requested"
    static let agentPlist = home + "/Library/LaunchAgents/\(AppInfo.agentLabel).plist"
    static let defaultKey = home + "/.ssh/storageboxsync_ed25519"
    static let knownHosts = home + "/.ssh/known_hosts"
    static let restoreRoot = home + "/Downloads/\(AppInfo.name) Restore"

    /// Prefer the rclone shipped inside the bundle so a Homebrew upgrade can never break scheduled backups.
    static var rclone: String {
        if let p = Bundle.main.path(forResource: "rclone", ofType: nil) { return p }
        for p in ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return "rclone"
    }
    static var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    static func ensure() {
        for d in [support, logs, home + "/Library/LaunchAgents", home + "/.ssh"] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
    }
}

/// Localized string lookup for text built outside SwiftUI views (runner, notifications, model messages).
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
