import Foundation

struct LiveProgress {
    var bytesLine = ""      // "1.2 GiB / 36 GiB, 3%, 12 MiB/s, ETA 48m"
    var checks = ""         // "123 / 21381, 1%"
    var transfers = ""      // "12 / 6618, 0%"
    var elapsed = ""
    var percent: Double?
    var current: [String] = []
}

struct PreviewItem: Identifiable {
    enum Kind: String { case upload, archive }
    let id = UUID()
    let kind: Kind
    let path: String
    let size: String
}

/// Everything the app knows about a run comes from rclone's own log file (`--log-level INFO --stats 5s`).
enum LogParser {
    static func tail(_ path: String, bytes: Int = 24_000) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    }

    static func progress(_ logFile: String) -> LiveProgress {
        var p = LiveProgress()
        var inTransferring = false
        var current: [String] = []
        for raw in tail(logFile).components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Transferred:") {
                inTransferring = false
                let v = l.dropFirst("Transferred:".count).trimmingCharacters(in: .whitespaces)
                if v.contains("B /") || v.contains("B/s") {
                    p.bytesLine = v
                    if let pc = v.split(separator: ",").dropFirst().first?.trimmingCharacters(in: .whitespaces),
                       pc.hasSuffix("%"), let d = Double(pc.dropLast()) { p.percent = d / 100 }
                } else {
                    p.transfers = v
                }
            } else if l.hasPrefix("Checks:") {
                p.checks = l.dropFirst("Checks:".count).trimmingCharacters(in: .whitespaces)
            } else if l.hasPrefix("Elapsed time:") {
                p.elapsed = l.dropFirst("Elapsed time:".count).trimmingCharacters(in: .whitespaces)
            } else if l.hasPrefix("Transferring:") {
                inTransferring = true; current = []
            } else if inTransferring && l.hasPrefix("*") {
                current.append(String(l.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else if !l.isEmpty {
                inTransferring = false
            }
        }
        p.current = current
        return p
    }

    struct Summary { var uploaded = 0, archived = 0, modtime = 0, errors = 0, bytes = "", lastError = "" }

    static func summarize(_ logFile: String, dryRun: Bool) -> Summary {
        var s = Summary()
        guard let text = try? String(contentsOfFile: logFile, encoding: .utf8) else { return s }
        text.enumerateLines { l, _ in
            if dryRun {
                if l.contains("Skipped copy as --dry-run") { s.uploaded += 1 }
                else if l.contains("Skipped move as --dry-run") || l.contains("Skipped delete as --dry-run") { s.archived += 1 }
                else if l.contains("Skipped update modification time") { s.modtime += 1 }
            } else {
                if l.contains(": Copied (new)") || l.contains(": Copied (replaced existing)") { s.uploaded += 1 }
                else if l.contains(": Moved (server-side)") { s.archived += 1 }
                else if l.contains("Updated modification time in destination") { s.modtime += 1 }
            }
            if l.contains(" ERROR ") { s.errors += 1; s.lastError = l }
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Transferred:") && t.contains("B /") {
                s.bytes = t.dropFirst("Transferred:".count).trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: ",").first ?? ""
            }
        }
        return s
    }

    static func preview(_ logFile: String) -> [PreviewItem] {
        guard let text = try? String(contentsOfFile: logFile, encoding: .utf8) else { return [] }
        var items: [PreviewItem] = []
        text.enumerateLines { l, _ in
            let kind: PreviewItem.Kind
            if l.contains("Skipped copy as --dry-run") { kind = .upload }
            else if l.contains("Skipped move as --dry-run") || l.contains("Skipped delete as --dry-run") { kind = .archive }
            else { return }
            // "2026/09/26 15:00:00 NOTICE: path/to/file: Skipped copy as --dry-run is set (size 1.2Mi)"
            guard let n = l.range(of: "NOTICE: "), let sk = l.range(of: ": Skipped ", options: .backwards),
                  n.upperBound <= sk.lowerBound else { return }
            var size = ""
            if let a = l.range(of: "(size "), let b = l.range(of: ")", options: .backwards), a.upperBound < b.lowerBound {
                size = String(l[a.upperBound..<b.lowerBound])
            }
            items.append(PreviewItem(kind: kind, path: String(l[n.upperBound..<sk.lowerBound]), size: size))
        }
        return items
    }
}
