import Foundation
import UserNotifications

typealias ShellResult = (code: Int32, out: String, err: String)

@discardableResult
func runCapture(_ exe: String, _ args: [String], stdin: String? = nil) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let o = Pipe(), e = Pipe()
    p.standardOutput = o; p.standardError = e
    let i = Pipe()
    if stdin != nil { p.standardInput = i }
    do { try p.run() } catch { return (-1, "", error.localizedDescription) }
    if let stdin {
        i.fileHandleForWriting.write(Data(stdin.utf8))
        try? i.fileHandleForWriting.close()
    }
    // Drain stderr concurrently so neither pipe can fill up and deadlock on large listings.
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    let outData = o.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
}

@discardableResult
func rclone(_ args: [String], config: String = Paths.rcloneConf) -> ShellResult {
    runCapture(Paths.rclone, ["--config", config] + args)
}

/// Last meaningful line of rclone's stderr, for user-facing error messages.
func lastErrorLine(_ s: String) -> String {
    s.split(separator: "\n").map(String.init).last { !$0.contains("NOTICE") && !$0.isEmpty } ?? s
}

/// Posts a notification as Burrow (headless runs too – the executable lives in the app bundle).
/// Falls back to AppleScript, shown as "Script Editor", only when the app was never asked for notification permission.
func notify(_ subtitle: String, _ text: String) {
    if ProcessInfo.processInfo.environment["BURROW_QUIET"] != nil { return }   // scripts/integration.sh
    if Bundle.main.bundleIdentifier != nil {
        let center = UNUserNotificationCenter.current()
        let done = DispatchSemaphore(value: 0)
        var status: UNAuthorizationStatus = .notDetermined
        center.getNotificationSettings { status = $0.authorizationStatus; done.signal() }
        _ = done.wait(timeout: .now() + 5)
        switch status {
        case .authorized, .provisional:
            let content = UNMutableNotificationContent()
            content.title = AppInfo.name
            content.subtitle = subtitle
            content.body = text
            let posted = DispatchSemaphore(value: 0)
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in posted.signal() }
            _ = posted.wait(timeout: .now() + 5)   // a headless run exits right after this
            return
        case .denied:
            return                                  // the user turned notifications off
        default:
            break
        }
    }
    let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    runCapture("/usr/bin/osascript", ["-e", "display notification \"\(esc(text))\" with title \"\(AppInfo.name)\" subtitle \"\(esc(subtitle))\""])
}

/// Asked once from the app, so later headless runs can post as Burrow.
func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
}
