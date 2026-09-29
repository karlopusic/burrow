import Foundation
import SwiftUI

struct Transfer: Identifiable, Codable {
    enum Kind: String, Codable { case upload, download, copy }
    enum State: String, Codable { case queued, running, paused, done, failed, cancelled }

    var id = UUID()
    var kind: Kind
    var name: String
    var server: String              // bookmark display name, for the list
    var isDir: Bool
    // rclone endpoints: a file transfer uses fs+remote pairs, a folder transfer uses whole fs paths.
    var srcFs: String
    var srcRemote: String?
    var dstFs: String
    var dstRemote: String?
    /// Human-readable destination, e.g. "~/Downloads/Report.pdf" or "Storage Box: Projects/Report.pdf"
    var destLabel: String
    var state: State = .queued
    var bytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speed: Double = 0
    var eta: Double?
    var files = 0
    var totalFiles = 0
    var error: String?
    var created = Date()
    var finished: Date?
    var jobID: Int?
    var wasStarted = false
    /// Remote folder (fs + path) to refresh in open browsers when this finishes.
    var refreshKey: String?

    var fraction: Double? { totalBytes > 0 ? min(1, Double(bytes) / Double(totalBytes)) : nil }
    var isActive: Bool { state == .queued || state == .running }
    var localDestination: String? {
        guard kind == .download else { return nil }
        return isDir ? dstFs : dstRemote.map { "/" + $0 }
    }

    // The fs strings may contain an obscured password – never persist them.
    enum CodingKeys: String, CodingKey {
        case id, kind, name, server, isDir, destLabel, state, bytes, totalBytes, files, totalFiles, error, created, finished
    }
    init(kind: Kind, name: String, server: String, isDir: Bool, srcFs: String, srcRemote: String?,
         dstFs: String, dstRemote: String?, destLabel: String, refreshKey: String?) {
        self.kind = kind; self.name = name; self.server = server; self.isDir = isDir
        self.srcFs = srcFs; self.srcRemote = srcRemote; self.dstFs = dstFs; self.dstRemote = dstRemote
        self.destLabel = destLabel; self.refreshKey = refreshKey
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); kind = try c.decode(Kind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name); server = try c.decode(String.self, forKey: .server)
        isDir = try c.decode(Bool.self, forKey: .isDir); destLabel = try c.decode(String.self, forKey: .destLabel)
        state = try c.decode(State.self, forKey: .state); bytes = try c.decode(Int64.self, forKey: .bytes)
        totalBytes = try c.decode(Int64.self, forKey: .totalBytes); files = try c.decode(Int.self, forKey: .files)
        totalFiles = try c.decode(Int.self, forKey: .totalFiles); error = try c.decodeIfPresent(String.self, forKey: .error)
        created = try c.decode(Date.self, forKey: .created); finished = try c.decodeIfPresent(Date.self, forKey: .finished)
        srcFs = ""; dstFs = ""
    }
}

extension Notification.Name {
    /// object: String refresh key ("<fs>|<path>") of a remote folder whose contents changed.
    static let remoteChanged = Notification.Name("remoteChanged")
}

@MainActor
final class TransferManager: ObservableObject {
    static let shared = TransferManager()

    @Published private(set) var items: [Transfer] = []
    var maxConcurrent = 2
    private var timer: Timer?
    private static let historyFile = Paths.support + "/transfers.json"

    private init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = FileManager.default.contents(atPath: Self.historyFile),
           let h = try? dec.decode([Transfer].self, from: d) {
            items = h.filter { !$0.isActive && $0.state != .paused }
        }
    }

    var activeCount: Int { items.filter(\.isActive).count }

    func enqueue(_ t: Transfer) {
        items.insert(t, at: 0)
        pump()
    }

    func pause(_ id: UUID) {
        guard let i = index(id), items[i].state == .running || items[i].state == .queued else { return }
        let job = items[i].jobID
        items[i].state = .paused
        items[i].jobID = nil
        if let job { stop(job) }
        pump()
    }

    /// rclone can't resume inside a single file over SFTP; a resumed folder transfer skips files that are already complete.
    func resume(_ id: UUID) {
        guard let i = index(id), [.paused, .failed, .cancelled].contains(items[i].state) else { return }
        items[i].state = .queued
        items[i].error = nil
        items[i].finished = nil
        pump()
    }

    func cancel(_ id: UUID) {
        guard let i = index(id), items[i].isActive || items[i].state == .paused else { return }
        let job = items[i].jobID
        items[i].state = .cancelled
        items[i].finished = Date()
        items[i].jobID = nil
        if let job { stop(job) }
        save(); pump()
    }

    /// An interrupted upload can leave a partial file. Its name is not proof that this job created it,
    /// so cancellation must never delete remote files by pattern.
    private func stop(_ job: Int) {
        Task {
            _ = try? await RcloneDaemon.shared.call("job/stop", ["jobid": job])
        }
    }

    func clearFinished() {
        items.removeAll { [.done, .failed, .cancelled].contains($0.state) }
        save()
    }

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func pump() {
        var running = items.filter { $0.state == .running }.count
        for t in items.reversed() where t.state == .queued {   // oldest first
            guard running < maxConcurrent else { break }
            if start(t.id) { running += 1 }
        }
        ensureTimer()
    }

    @discardableResult
    private func start(_ id: UUID) -> Bool {
        guard let i = index(id) else { return false }
        if items[i].kind == .download, !items[i].wasStarted,
           let destination = items[i].localDestination,
           FileManager.default.fileExists(atPath: destination) {
            items[i].state = .failed
            items[i].error = L("Download destination already exists: %@", destination)
            items[i].finished = Date()
            save()
            return false
        }
        items[i].wasStarted = true
        items[i].state = .running
        items[i].bytes = 0
        let t = items[i]
        var params: [String: Any]
        let command: String
        if t.isDir {
            command = "sync/copy"
            params = ["srcFs": t.srcFs, "dstFs": t.dstFs, "createEmptySrcDirs": true]
        } else {
            command = "operations/copyfile"
            params = ["srcFs": t.srcFs, "srcRemote": t.srcRemote ?? "", "dstFs": t.dstFs, "dstRemote": t.dstRemote ?? ""]
        }
        params["_async"] = true
        params["_config"] = RcloneDaemon.noOverwrite   // the conflict check ran when queued; the server may have changed since
        params["_group"] = "t-\(t.id.uuidString)"
        Task {
            do {
                let r = try await RcloneDaemon.shared.call(command, params)
                guard let j = index(id) else { return }
                if items[j].state == .running { items[j].jobID = (r["jobid"] as? NSNumber)?.intValue }
            } catch {
                finish(id, .failed, error.localizedDescription)
            }
        }
        return true
    }

    private func ensureTimer() {
        guard timer == nil, items.contains(where: { $0.state == .running }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    private func poll() async {
        let running = items.filter { $0.state == .running && $0.jobID != nil }
        if items.allSatisfy({ $0.state != .running }) {
            timer?.invalidate(); timer = nil
            return
        }
        for t in running {
            guard let job = t.jobID else { continue }
            let stats = try? await RcloneDaemon.shared.call("core/stats", ["group": "t-\(t.id.uuidString)"])
            let status = try? await RcloneDaemon.shared.call("job/status", ["jobid": job])
            guard let i = index(t.id), items[i].state == .running else { continue }
            if let s = stats {
                items[i].bytes = (s["bytes"] as? NSNumber)?.int64Value ?? items[i].bytes
                let total = (s["totalBytes"] as? NSNumber)?.int64Value ?? 0
                if total > 0 { items[i].totalBytes = total }
                items[i].speed = (s["speed"] as? NSNumber)?.doubleValue ?? 0
                items[i].eta = (s["eta"] as? NSNumber)?.doubleValue
                items[i].files = (s["transfers"] as? NSNumber)?.intValue ?? 0
                items[i].totalFiles = (s["totalTransfers"] as? NSNumber)?.intValue ?? 0
            }
            if let st = status, (st["finished"] as? Bool) == true {
                if (st["success"] as? Bool) == true {
                    if items[i].totalBytes == 0 { items[i].totalBytes = items[i].bytes }
                    finish(t.id, .done, nil)
                } else {
                    finish(t.id, .failed, RcloneDaemon.clean(st["error"] as? String ?? "failed"))
                }
            }
        }
    }

    private func finish(_ id: UUID, _ state: Transfer.State, _ error: String?) {
        guard let i = index(id) else { return }
        items[i].state = state
        items[i].error = error
        items[i].finished = Date()
        items[i].jobID = nil
        if let key = items[i].refreshKey { NotificationCenter.default.post(name: .remoteChanged, object: key) }
        let t = items[i]
        if state == .done && activeCount == 0 {
            let text = t.kind == .download ? L("Downloaded: %@", t.name) : L("Uploaded: %@", t.name)
            Task.detached { notify(L("Transfers finished"), text) }
        } else if state == .failed {
            let text = "\(t.name): \(error ?? "")"
            Task.detached { notify(L("Transfer failed"), text) }
        }
        save(); pump()
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let history = Array(items.filter { !$0.isActive && $0.state != .paused }.prefix(300))
        if let d = try? enc.encode(history) { try? d.write(to: URL(fileURLWithPath: Self.historyFile), options: .atomic) }
    }
}
