import SwiftUI

/// One place that decides how the backup's state is presented (overview, sidebar, menu bar).
struct BackupState {
    enum Kind { case setup, running, never, ok, overdue, blocked, failed, stopped }
    let kind: Kind

    @MainActor init(_ model: AppModel) {
        let last = model.status.lastBackup
        if model.needsSetup { kind = .setup }
        else if model.isRunning { kind = .running }
        else if last?.result == .blocked { kind = .blocked }
        else if last?.result == .error { kind = .failed }
        else if last?.result == .stopped { kind = .stopped }
        else if let end = model.status.lastSuccess?.end {
            // overdue: a scheduled run should have happened more than 12 hours ago
            if let due = model.cfg.nextRun(after: end), due.addingTimeInterval(12 * 3600) < Date() { kind = .overdue }
            else { kind = .ok }
        } else { kind = .never }
    }

    var tint: Color {
        switch kind {
        case .ok: return .green
        case .running: return .accentColor
        case .overdue, .blocked, .failed: return .orange
        case .setup, .never: return .blue
        case .stopped: return .gray
        }
    }

    var icon: String {
        switch kind {
        case .ok: return "checkmark"
        case .running: return "arrow.triangle.2.circlepath"
        case .overdue: return "clock.badge.exclamationmark"
        case .blocked: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.fill"
        case .setup: return "wrench.and.screwdriver.fill"
        case .never: return "externaldrive"
        }
    }

    var sidebarIcon: String {
        switch kind {
        case .ok: return "checkmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath.circle.fill"
        case .overdue, .blocked, .failed: return "exclamationmark.circle.fill"
        default: return "externaldrive"
        }
    }

    var menuBarIcon: String {
        switch kind {
        case .running: return "arrow.triangle.2.circlepath.icloud"
        case .overdue, .blocked, .failed: return "externaldrive.badge.exclamationmark"
        default: return "externaldrive.badge.checkmark"
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    var openSettings: () -> Void
    @State private var showPreview = false

    var body: some View {
        let state = BackupState(model)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                banners
                if state.kind != .setup {
                    hero(state)
                    stats
                    route
                }
                if let d = model.status.lastDryRun, !model.isRunning { dryRunCard(d) }
                history
            }
            .padding(20)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showPreview) {
            if let d = model.status.lastDryRun { PreviewSheet(record: d) }
        }
    }

    @ViewBuilder private var banners: some View {
        if model.needsSetup {
            Banner(icon: "wrench.and.screwdriver.fill", tint: .blue, title: "Finish setup",
                   text: "Enter your SFTP server connection and choose the folder to back up.",
                   actions: AnyView(HStack {
                       Button("Open Setup Assistant") { model.showOnboarding = true }.buttonStyle(.borderedProminent)
                       Button("Open Settings", action: openSettings)
                   }))
        }
        if model.migration == .waitingForLegacyRun {
            Banner(icon: "hourglass", tint: .blue, title: "Waiting for the previous app",
                   text: "A backup started by the previous version of the app is still running. Settings will be imported automatically once it finishes – reopen this app then.")
        }
        if model.shouldOfferMove {
            Banner(icon: "arrow.down.app.fill", tint: .orange, title: "Move Burrow to Applications",
                   text: "The app is running from the disk image or a temporary location. Scheduled backups need it in the Applications folder.",
                   actions: AnyView(Button("Move to Applications") { model.moveToApplications() }.buttonStyle(.borderedProminent)))
        }
        if !model.localAccess && !model.checkingAccess {
            Banner(icon: "lock.fill", tint: .orange, title: "No access to the local folder",
                   text: "Scheduled backups can't read this folder yet. Click “Check again” and allow access when macOS asks. If you chose “Don't Allow” before, turn Burrow on in System Settings → Privacy & Security → Files and Folders.",
                   actions: AnyView(HStack {
                       Button("Check again") { model.checkLocalAccess() }.buttonStyle(.borderedProminent)
                       Button("Open Files and Folders") { model.openFilesAndFolders() }
                   }))
        }
    }

    // MARK: hero

    private func hero(_ state: BackupState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle().fill(state.tint.gradient)
                    Image(systemName: state.icon)
                        .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: state.kind == .running)
                }
                .frame(width: 58, height: 58)
                .shadow(color: state.tint.opacity(0.35), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    title(state).font(.title2.bold())
                    subtitle(state).foregroundStyle(.secondary)
                    if let l = model.status.lastBackup, [.blocked, .failed].contains(state.kind), !l.message.isEmpty {
                        Text(l.message).font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            if state.kind == .running { progress } else { actions }
        }
        .card(tint: state.tint, padding: 20)
    }

    private func title(_ state: BackupState) -> Text {
        switch state.kind {
        case .running: return model.status.running?.dryRun == true ? Text("Preview in progress…") : Text("Backup in progress…")
        case .ok: return Text("Your backup is up to date")
        case .overdue: return Text("Backup overdue")
        case .blocked: return Text("Backup blocked for safety")
        case .failed: return Text("The last backup failed")
        case .stopped: return Text("The last backup was stopped")
        case .never, .setup: return Text("No successful backup yet")
        }
    }

    private func subtitle(_ state: BackupState) -> Text {
        if state.kind == .running, let r = model.status.running {
            return Text("Started \(Fmt.dayTime.string(from: r.start))")
        }
        if let e = model.status.lastSuccess?.end {
            return Text("Last successful backup: \(Fmt.relative.localizedString(for: e, relativeTo: Date()))")
                + Text(verbatim: " · \(Fmt.date.string(from: e))")
        }
        return Text("Run the first backup now – or preview what it would upload.")
    }

    private var progress: some View {
        let p = model.progress ?? LiveProgress()
        return VStack(alignment: .leading, spacing: 10) {
            if let pc = p.percent { ProgressView(value: pc) } else { ProgressView().progressViewStyle(.linear) }
            HStack(alignment: .top, spacing: 24) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    if !p.bytesLine.isEmpty { GridRow { Text("Data").foregroundStyle(.secondary); Text(verbatim: p.bytesLine) } }
                    if !p.transfers.isEmpty { GridRow { Text("Files").foregroundStyle(.secondary); Text(verbatim: p.transfers) } }
                    if !p.checks.isEmpty { GridRow { Text("Checked").foregroundStyle(.secondary); Text(verbatim: p.checks) } }
                    if !p.elapsed.isEmpty { GridRow { Text("Elapsed").foregroundStyle(.secondary); Text(verbatim: p.elapsed) } }
                }
                .font(.callout.monospacedDigit())
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button(role: .destructive) { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .controlSize(.large)
                    if let r = model.status.running {
                        Button("Open log") { model.openLog(r.logFile) }.buttonStyle(.link)
                    }
                }
            }
            if !p.current.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(p.current.prefix(4), id: \.self) {
                        Text(verbatim: $0).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
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
        }
        .disabled(model.isRunning || model.needsSetup)
    }

    // MARK: key figures

    private var stats: some View {
        HStack(alignment: .top, spacing: 12) {
            if let n = model.cfg.nextRun() {
                StatTile(title: "Next backup", systemImage: "calendar", tint: .blue,
                         value: Text(Fmt.dayTime.string(from: n)),
                         detail: model.cfg.frequency == .daily ? Text("Every day") : Text("Once a week"))
            } else {
                StatTile(title: "Next backup", systemImage: "calendar", tint: .gray,
                         value: Text("Off"), detail: Text("Scheduled backups are off"))
            }
            if let b = model.boxSpace, b.total > 0 {
                StatTile(title: "Server storage", systemImage: "externaldrive.fill", tint: .teal,
                         value: Text("\(Fmt.bytes(b.used)) of \(Fmt.bytes(b.total))"),
                         detail: Text("\(Fmt.bytes(max(b.total - b.used, 0))) free"),
                         gauge: Double(b.used) / Double(b.total))
            } else {
                StatTile(title: "Server storage", systemImage: "externaldrive.fill", tint: .teal,
                         value: Text(verbatim: "—"),
                         detail: model.boxSpaceChecked ? Text("Quota unavailable on this server") : Text("Checking…"))
            }
            StatTile(title: "Old versions", systemImage: "clock.arrow.circlepath", tint: .orange,
                     value: Text("\(model.cfg.retentionDays) days"),
                     detail: Text("Changed and deleted files are kept"))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var route: some View {
        HStack(spacing: 14) {
            endpoint(icon: "folder.fill", tint: .blue,
                     name: (model.cfg.localPath as NSString).lastPathComponent, path: model.cfg.localPath)
            Image(systemName: "arrow.right").font(.title3.weight(.semibold)).foregroundStyle(.tertiary)
            endpoint(icon: "server.rack", tint: .teal,
                     name: model.cfg.host, path: model.cfg.remotePath)
            Spacer(minLength: 0)
            Button { model.openLocalFolder() } label: { Image(systemName: "folder") }
                .help("Open local folder").buttonStyle(.borderless).font(.title3)
        }
        .card(padding: 14)
    }

    private func endpoint(icon: String, tint: Color, name: String, path: String) -> some View {
        HStack(spacing: 10) {
            IconBadge(systemImage: icon, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name).font(.headline).lineLimit(1)
                Text(verbatim: path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    // MARK: preview & history

    private func dryRunCard(_ d: RunRecord) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: "eye.fill", tint: .indigo, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Last preview · \(Fmt.date.string(from: d.start))").font(.headline)
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
        .card(padding: 14)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "History") {
                Button { model.openLogsFolder() } label: { Label("Open logs folder", systemImage: "doc.text.magnifyingglass") }
                    .buttonStyle(.borderless).font(.callout)
            }
            VStack(spacing: 0) {
                if model.status.runs.isEmpty {
                    Text("No runs yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(Array(model.status.runs.prefix(25).enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Divider().padding(.leading, 44) }
                    historyRow(r)
                }
            }
            .card(padding: 0)
        }
    }

    private func historyRow(_ r: RunRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(r)).font(.title3).foregroundStyle(color(r)).frame(width: 22)
            Text(Fmt.date.string(from: r.start)).monospacedDigit().frame(width: 150, alignment: .leading)
            Group {
                if r.dryRun { StatusPill(text: Text("preview"), tint: .indigo) }
                else if r.trigger == .schedule { StatusPill(text: Text("scheduled"), tint: .blue) }
                else { StatusPill(text: Text("manual"), tint: .gray) }
            }
            .frame(width: 90, alignment: .leading)
            if r.result == .ok {
                Text(verbatim: "↑ \(r.uploaded)   ⟲ \(r.archived)\(r.bytes.isEmpty ? "" : "   · \(r.bytes)")").lineLimit(1)
            } else {
                Text(r.message).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.duration(r.start, r.end)).foregroundStyle(.secondary).monospacedDigit()
            Button { model.openLog(r.logFile) } label: { Image(systemName: "doc.text") }
                .buttonStyle(.borderless).help("Open log")
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func icon(_ r: RunRecord) -> String {
        switch r.result {
        case .ok: return r.dryRun ? "eye.circle.fill" : "checkmark.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .blocked: return "hand.raised.circle.fill"
        case .running: return "arrow.triangle.2.circlepath.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(_ r: RunRecord) -> Color {
        switch r.result {
        case .ok: return r.dryRun ? .indigo : .green
        case .stopped, .running: return .secondary
        default: return .orange
        }
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
            Text("“upload” = a new or changed file goes to the server. “archive” = the old server copy moves to the versions folder.")
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
