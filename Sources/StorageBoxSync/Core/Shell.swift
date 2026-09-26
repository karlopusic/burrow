import Foundation

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

func notify(_ subtitle: String, _ text: String) {
    let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    runCapture("/usr/bin/osascript", ["-e", "display notification \"\(esc(text))\" with title \"\(AppInfo.name)\" subtitle \"\(esc(subtitle))\""])
}
