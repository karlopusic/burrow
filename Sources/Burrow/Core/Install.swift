import Foundation
import Darwin

/// Where the app runs from. The LaunchAgent stores the executable's path, so scheduled backups only work when that
/// path survives: not from the mounted DMG (gone after ejecting), and not from App Translocation – macOS runs a
/// downloaded app that wasn't moved by Finder from a random read-only path that disappears after it quits.
enum Install {
    enum Location: Equatable {
        case applications       // /Applications or ~/Applications
        case elsewhere          // a stable path the user chose (e.g. ~/Tools) – works, but not recommended
        case translocated
        case diskImage
    }

    static func location(of bundlePath: String, home: String = Paths.home) -> Location {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if bundlePath.hasPrefix("/Volumes/") { return .diskImage }
        let parent = (bundlePath as NSString).deletingLastPathComponent
        if parent == "/Applications" || parent == home + "/Applications" { return .applications }
        return .elsewhere
    }

    static var current: Location { location(of: Bundle.main.bundlePath) }

    /// The schedule may only point at an executable whose path lasts.
    static func canSchedule(_ l: Location) -> Bool { l == .applications || l == .elsewhere }

    /// A development build started straight from the repository's build folder stays where it is.
    static var isDevelopmentBuild: Bool { Bundle.main.bundlePath.hasSuffix("/build/\(AppInfo.name).app") }

    /// Copies the running app into /Applications (or ~/Applications without write access there) and returns the new
    /// path. An older copy at the target goes to the Trash first. The quarantine flag is removed from the copy –
    /// the user already opened this app through Gatekeeper, and a quarantined copy would be translocated again.
    static func moveToApplications() throws -> String {
        let fm = FileManager.default
        let source = Bundle.main.bundlePath
        let name = (source as NSString).lastPathComponent
        let system = "/Applications"
        let folder = fm.isWritableFile(atPath: system) ? system : Paths.home + "/Applications"
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let target = folder + "/" + name
        if fm.fileExists(atPath: target) {
            try fm.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: nil)
        }
        try fm.copyItem(atPath: source, toPath: target)
        runCapture("/usr/bin/xattr", ["-d", "-r", "com.apple.quarantine", target])
        return target
    }
}
