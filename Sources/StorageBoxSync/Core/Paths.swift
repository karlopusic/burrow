import Foundation

enum AppInfo {
    static let name = "StorageBox Sync"
    static let bundleID = "hr.push.storageboxsync"
    /// A dev instance started with CFFIXED_USER_HOME (a throw-away home) gets its own agent, so it can never
    /// replace – or `launchctl bootout` – the real scheduled backup.
    static let agentLabel = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == nil ? bundleID : bundleID + ".dev"
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

/// UI language chosen in Settings. English unless the user picks another one – independent of the system language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case en, hr, de
    var id: String { rawValue }
    static let key = "appLanguage"

    /// Always shown in its own language, so it can be found whatever the UI currently is.
    var nativeName: String {
        switch self {
        case .en: return "English"
        case .hr: return "Hrvatski"
        case .de: return "Deutsch"
        }
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .en
    }

    /// Must run first thing in main(), before any localized string is loaded (GUI and headless runs alike).
    static func apply() {
        UserDefaults.standard.set([current.rawValue], forKey: "AppleLanguages")
    }

    static func set(_ lang: AppLanguage) {
        UserDefaults.standard.set(lang.rawValue, forKey: key)
        UserDefaults.standard.set([lang.rawValue], forKey: "AppleLanguages")
    }
}

/// Localized string lookup for text built outside SwiftUI views (runner, notifications, model messages).
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
