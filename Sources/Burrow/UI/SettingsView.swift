import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = AppConfig()
    @State private var time = Date()
    @State private var language = AppLanguage.current
    @State private var showAbout = false
    private let launchLanguage = AppLanguage.current

    var body: some View {
        Form {
            connectionSection
            Section("Folders") {
                LabeledContent {
                    HStack {
                        Text(verbatim: draft.localPath.isEmpty ? "—" : draft.localPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { pickFolder() }
                    }
                } label: {
                    Label { Text("Local folder") } icon: { Image(systemName: "folder.fill").foregroundStyle(.blue) }
                }
                TextField("Backup folder on server", text: $draft.remotePath, prompt: Text(verbatim: "Projects"))
                TextField("Versions folder on server", text: $draft.versionsPath, prompt: Text(verbatim: "_versions"))
                if let p = current.folderProblem {
                    Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("The backup folder becomes an exact mirror of the local folder. Changed or deleted files move to the versions folder instead of being overwritten.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.cfg.isComplete && current.backupPair != model.cfg.backupPair {
                    Label("Files in the server folder that aren't in the local folder will be moved to the versions folder and deleted for good after \(draft.retentionDays) days. If the local folder has far fewer files than the server folder, the next backup waits for you to confirm it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Schedule") {
                Toggle("Automatic backup", isOn: $draft.scheduleEnabled)
                Picker("Frequency", selection: $draft.frequency) {
                    Text("Every day").tag(Frequency.daily)
                    Text("Once a week").tag(Frequency.weekly)
                }.disabled(!draft.scheduleEnabled)
                if draft.frequency == .weekly {
                    Picker("Day", selection: $draft.weekday) {
                        ForEach(1...7, id: \.self) { Text(Fmt.weekdays[$0 - 1].capitalized).tag($0) }
                    }.disabled(!draft.scheduleEnabled)
                }
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .disabled(!draft.scheduleEnabled)
                Text("If the Mac is asleep or off at that time, the backup runs when it wakes up or at the next login.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Versions & safety") {
                Stepper("Keep old versions for \(draft.retentionDays) days", value: $draft.retentionDays, in: 7...365, step: 7)
                Stepper("Stop if a run would archive more than \(draft.maxDelete) files", value: $draft.maxDelete, in: 50...5000, step: 50)
                Text("If more than 20 percent of local files disappear between backups, the run is blocked until you confirm it manually.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Language") {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.nativeName).tag($0) }
                }
                .onChange(of: language) { _, l in AppLanguage.set(l) }
                if language != launchLanguage {
                    HStack {
                        Text("The new language is used after the app restarts.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { model.relaunch() }
                    }
                }
            }
            Section("Permissions") {
                HStack {
                    Button("Check access") { model.checkLocalAccess() }.disabled(model.checkingAccess)
                    Button("Open Files and Folders") { model.openFilesAndFolders() }
                    if model.checkingAccess {
                        ProgressView().controlSize(.small)
                    } else {
                        (model.localAccess ? Text("Local folder is readable ✓") : Text("No access to the local folder"))
                            .foregroundStyle(model.localAccess ? Color.secondary : Color.orange)
                    }
                }
            }
            HStack {
                Button("About Burrow…") { showAbout = true }
                Spacer()
                Button("Revert") { load() }.disabled(current == model.cfg)
                Button("Save") { model.saveConfig(current) }
                    .buttonStyle(.borderedProminent).disabled(current == model.cfg || current.folderProblem != nil)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
        .sheet(isPresented: $showAbout) { AboutView() }
    }

    private var connectionSection: some View {
        Section {
            let usable = model.bookmarks.filter { $0.auth == .key }
            Picker("Server", selection: Binding(
                get: { draft.backupBookmarkID },
                set: { id in if let b = model.bookmarks.first(where: { $0.id == id }) { draft.use(b) } })) {
                if draft.backupBookmarkID == nil && draft.isConnectionConfigured {
                    // set up before servers existed: keep showing the connection the backup really uses
                    Text(verbatim: "\(draft.user)@\(draft.host)").tag(UUID?.none)
                } else {
                    Text("Choose…").tag(UUID?.none)
                }
                ForEach(usable) { b in Text(b.displayName).tag(UUID?.some(b.id)) }
            }
            let passwordOnly = model.bookmarks.filter { $0.auth != .key }
            let passwordNames = passwordOnly.map(\.displayName).joined(separator: ", ")
            if !passwordOnly.isEmpty {
                Text("Backups run unattended and need an SSH key. Not listed because they use a password: \(passwordNames). To switch one to an SSH key, right-click it under Servers and choose Edit…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if usable.isEmpty {
                Text("Add a server with SSH key authentication under Servers in the sidebar first.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Backups run unattended, so only servers that use an SSH key are listed. Edit connection details under Servers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Test connection") { model.testConnection(current) }.disabled(!draft.isConnectionConfigured)
                if let c = model.connection { Text(c).foregroundStyle(.secondary).lineLimit(2) }
            }
        } header: {
            Text("Backup destination")
        }
    }

    private var current: AppConfig {
        var c = draft
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        c.hour = comps.hour ?? 21; c.minute = comps.minute ?? 0
        c.host = c.host.trimmingCharacters(in: .whitespaces)
        c.user = c.user.trimmingCharacters(in: .whitespaces)
        c.remotePath = c.remotePath.trimmingCharacters(in: .whitespaces)
        c.versionsPath = c.versionsPath.trimmingCharacters(in: .whitespaces)
        return c
    }

    private func load() {
        draft = model.cfg
        time = Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: Date()) ?? Date()
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        if !draft.localPath.isEmpty { p.directoryURL = URL(fileURLWithPath: draft.localPath) }
        if p.runModal() == .OK, let u = p.url { draft.localPath = u.path }
    }
}
