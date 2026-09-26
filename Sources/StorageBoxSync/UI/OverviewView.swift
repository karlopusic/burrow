import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    var openSettings: () -> Void
    @State private var showPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                banners
                statusCard
                if model.isRunning { progressCard }
                actions
                if let d = model.status.lastDryRun, !model.isRunning { dryRunCard(d) }
                history
            }
            .padding(8)
        }
        .sheet(isPresented: $showPreview) {
            if let d = model.status.lastDryRun { PreviewSheet(record: d) }
        }
    }

    @ViewBuilder private var banners: some View {
        if model.needsSetup {
            Banner(icon: "wrench.and.screwdriver", tint: .blue, title: "Finish setup",
                   text: "Enter your Storage Box connection and choose the folder to back up.",
                   actions: AnyView(Button("Open Settings", action: openSettings)))
        }
        if model.migration == .waitingForLegacyRun {
            Banner(icon: "hourglass", tint: .blue, title: "Waiting for the previous app",
                   text: "A backup started by SIM Backup is still running. Settings will be imported automatically once it finishes – reopen this app then.")
        }
        if !model.localAccess {
            Banner(icon: "lock.trianglebadge.exclamationmark", tint: .orange, title: "No access to the local folder",
                   text: "Add StorageBox Sync in System Settings → Privacy & Security → Full Disk Access, then reopen the app. Scheduled backups can't read protected folders like Desktop without it.",
                   actions: AnyView(HStack {
                       Button("Open Full Disk Access") { model.openFullDiskAccess() }
                       Button("Check again") { model.checkLocalAccess() }
                   }))
        }
    }

    private var statusCard: some View {
        let last = model.status.lastBackup
        let ok = last?.result == .ok
        return HStack(alignment: .top, spacing: 16) {
            Image(systemName: last == nil ? "externaldrive" : (ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                .font(.system(size: 38))
                .foregroundStyle(last == nil ? Color.secondary : (ok ? Color.green : Color.orange))
            VStack(alignment: .leading, spacing: 4) {
                if let s = model.status.lastSuccess, let e = s.end {
                    Text("Last successful backup: \(Fmt.relative.localizedString(for: e, relativeTo: Date()))")
                        .font(.title3.bold())
                    Text(Fmt.date.string(from: e)).foregroundStyle(.secondary)
                } else {
                    Text("No successful backup yet").font(.title3.bold())
                }
                if let l = last, l.result != .ok, l.result != .running {
                    Text(l.message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Group {
                    if let n = model.cfg.nextRun(), model.cfg.isComplete {
                        Text("Next scheduled run: \(Fmt.date.string(from: n))")
                    } else {
                        Text("Scheduled backups are off")
                    }
                    if let b = model.boxSpace {
                        Text("Storage Box: \(Fmt.bytes(b.used)) of \(Fmt.bytes(b.total)) used")
                    }
                    if model.cfg.isComplete {
                        Text(verbatim: "\(model.cfg.localPath)  →  \(model.cfg.host):\(model.cfg.remotePath)")
                            .font(.caption).textSelection(.enabled)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var progressCard: some View {
        let p = model.progress ?? LiveProgress()
        let dry = model.status.running?.dryRun == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                (dry ? Text("Preview in progress…") : Text("Backup in progress…")).bold()
                Spacer()
                Button(role: .destructive) { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            }
            if let pc = p.percent { ProgressView(value: pc) } else { ProgressView().progressViewStyle(.linear) }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if !p.bytesLine.isEmpty { GridRow { Text("Data").foregroundStyle(.secondary); Text(verbatim: p.bytesLine) } }
                if !p.transfers.isEmpty { GridRow { Text("Files").foregroundStyle(.secondary); Text(verbatim: p.transfers) } }
                if !p.checks.isEmpty { GridRow { Text("Checked").foregroundStyle(.secondary); Text(verbatim: p.checks) } }
                if !p.elapsed.isEmpty { GridRow { Text("Elapsed").foregroundStyle(.secondary); Text(verbatim: p.elapsed) } }
            }
            .font(.callout.monospacedDigit())
            ForEach(p.current.prefix(4), id: \.self) { Text(verbatim: $0).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let r = model.status.running {
                Button("Open log") { model.openLog(r.logFile) }.buttonStyle(.link)
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { model.startBackup() } label: { Label("Back up now", systemImage: "arrow.up.circle.fill") }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button { model.startDryRun() } label: { Label("Preview changes", systemImage: "eye") }
                .controlSize(.large)
            if model.status.lastBackup?.result == .blocked {
                Button { model.startBackup(force: true) } label: { Label("Run anyway", systemImage: "exclamationmark.shield") }
                    .controlSize(.large)
            }
            Spacer()
            Button { model.openLocalFolder() } label: { Image(systemName: "folder") }.help("Open local folder")
            Button { model.openLogsFolder() } label: { Image(systemName: "doc.text.magnifyingglass") }.help("Open logs folder")
        }
        .disabled(model.isRunning || model.needsSetup)
    }

    private func dryRunCard(_ d: RunRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last preview · \(Fmt.date.string(from: d.start))").bold()
                if d.result == .ok {
                    Text("To upload: \(d.uploaded) · To archive: \(d.archived) · Date fixes: \(d.modtimeFixed)")
                        .foregroundStyle(.secondary)
                } else {
                    Text(d.message).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Show list") { showPreview = true }.disabled(d.result != .ok)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History").font(.headline)
            if model.status.runs.isEmpty {
                Text("No runs yet.").foregroundStyle(.secondary)
            }
            ForEach(model.status.runs.prefix(25)) { r in
                HStack(spacing: 10) {
                    Image(systemName: icon(r)).foregroundStyle(color(r)).frame(width: 18)
                    Text(Fmt.date.string(from: r.start)).monospacedDigit().frame(width: 160, alignment: .leading)
                    (r.dryRun ? Text("preview") : (r.trigger == .schedule ? Text("scheduled") : Text("manual")))
                        .foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    if r.result == .ok {
                        Text(verbatim: "↑ \(r.uploaded)  ⟲ \(r.archived)\(r.bytes.isEmpty ? "" : "  · \(r.bytes)")").lineLimit(1)
                    } else {
                        Text(r.message).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                    Text(Fmt.duration(r.start, r.end)).foregroundStyle(.secondary).monospacedDigit()
                    Button { model.openLog(r.logFile) } label: { Image(systemName: "doc.text") }.buttonStyle(.borderless)
                }
                .font(.callout)
                Divider()
            }
        }
    }

    private func icon(_ r: RunRecord) -> String {
        switch r.result {
        case .ok: return r.dryRun ? "eye.circle" : "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        case .blocked: return "hand.raised.circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(_ r: RunRecord) -> Color {
        switch r.result { case .ok: return .green; case .stopped, .running: return .secondary; default: return .orange }
    }
}

struct PreviewSheet: View {
    let record: RunRecord
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PreviewItem] = []
    @State private var filter = ""
    @State private var kind: PreviewItem.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Preview · \(Fmt.date.string(from: record.start))").font(.title3.bold())
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("“upload” = new or changed file goes to the box. “archive” = the old copy on the box moves to the versions folder – nothing is deleted.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("", selection: $kind) {
                    Text("All (\(items.count))").tag(PreviewItem.Kind?.none)
                    Text("Upload (\(items.filter { $0.kind == .upload }.count))").tag(PreviewItem.Kind?.some(.upload))
                    Text("Archive (\(items.filter { $0.kind == .archive }.count))").tag(PreviewItem.Kind?.some(.archive))
                }
                .pickerStyle(.segmented).frame(width: 380)
                TextField("Search…", text: $filter).textFieldStyle(.roundedBorder)
            }
            Table(shown) {
                TableColumn("Type") { i in
                    (i.kind == .upload ? Text("upload") : Text("archive")).foregroundStyle(i.kind == .archive ? .orange : .primary)
                }.width(70)
                TableColumn("Path", value: \.path)
                TableColumn("Size", value: \.size).width(80)
            }
        }
        .padding(16)
        .frame(width: 880, height: 560)
        .onAppear { items = LogParser.preview(record.logFile) }
    }

    private var shown: [PreviewItem] {
        items.filter { (kind == nil || $0.kind == kind) && (filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter)) }
    }
}
