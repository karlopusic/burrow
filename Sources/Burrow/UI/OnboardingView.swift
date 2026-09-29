import SwiftUI
import AppKit

/// First-run assistant: server → confirm host key → SSH key → folders → schedule. Creates the bookmark and the
/// backup configuration in one go, so a new user never has to find their way through Settings.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var verifier = HostVerifier()

    enum Step: Int, CaseIterable { case welcome, server, key, folders, schedule, done }
    @State private var step: Step = .welcome

    // server
    @State private var isStorageBox = false
    @State private var bookmark: Bookmark = {
        var b = Bookmark()
        b.keyFile = Paths.defaultKey
        return b
    }()
    // key
    @State private var hasKey = true
    @State private var password = ""
    @State private var keyCheck: KeySetup.Outcome?
    @State private var checkingKey = false
    // folders
    @State private var cfg = AppConfig()
    @State private var remoteEdited = false
    @State private var remoteCount: Int?
    @State private var inspecting = false
    @State private var inspectError: String?
    @State private var acceptNonEmpty = false
    // schedule
    @State private var time = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome && step != .done { stepper.padding(.top, 18) }
            Group {
                switch step {
                case .welcome: welcome
                case .server: server
                case .key: key
                case .folders: folders
                case .schedule: schedule
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32).padding(.vertical, 20)
            Divider()
            footer.padding(16)
        }
        .frame(width: 640, height: 560)
        .hostKeyVerification(verifier)
        .onAppear { model.keySetupResult = nil }
        .onChange(of: model.keySetupResult?.message) { _, _ in
            if let r = model.keySetupResult { keyCheck = r }
        }
    }

    // MARK: chrome

    private var stepper: some View {
        HStack(spacing: 6) {
            ForEach([Step.server, .key, .folders, .schedule], id: \.self) { s in
                let reached = step.rawValue >= s.rawValue
                HStack(spacing: 6) {
                    Image(systemName: step.rawValue > s.rawValue ? "checkmark.circle.fill" : "\(s.rawValue).circle.fill")
                        .foregroundStyle(reached ? Color.accentColor : Color.secondary.opacity(0.5))
                    stepTitle(s).font(.callout.weight(step == s ? .semibold : .regular))
                        .foregroundStyle(reached ? .primary : .secondary)
                }
                if s != .schedule {
                    Rectangle().fill(step.rawValue > s.rawValue ? Color.accentColor : Theme.hairline)
                        .frame(height: 2).frame(maxWidth: 40)
                }
            }
        }
    }

    private func stepTitle(_ s: Step) -> Text {
        switch s {
        case .server: return Text("Server")
        case .key: return Text("SSH key")
        case .folders: return Text("Folders")
        default: return Text("Schedule")
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            switch step {
            case .welcome:
                Button("Set Up Later") { model.skipOnboarding(); dismiss() }
                Spacer()
                Button("Get Started") { step = .server }.keyboardShortcut(.defaultAction)
            case .done:
                Button("Close") { dismiss() }
                Spacer()
                Button("Back up now") { model.startBackup(); dismiss() }
                Button("Preview changes") { model.startDryRun(); dismiss() }.keyboardShortcut(.defaultAction)
            default:
                Button("Back") { back() }
                if verifier.checking || checkingKey || inspecting || model.keySetupBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                (step == .schedule ? Button("Finish") { next() } : Button("Continue") { next() })
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
    }

    private var canContinue: Bool {
        switch step {
        case .server: return bookmark.isComplete && !verifier.checking
        case .key: return keyCheck?.ok == true
        case .folders:
            return !cfg.localPath.isEmpty && !cfg.remotePath.isEmpty && !cfg.versionsPath.isEmpty
                && cfg.folderProblem == nil && !inspecting && ((remoteCount ?? 0) == 0 || acceptNonEmpty)
        default: return true
        }
    }

    private func back() {
        if let s = Step(rawValue: step.rawValue - 1) { step = s }
    }

    private func next() {
        switch step {
        case .server:
            bookmark.host = bookmark.host.trimmingCharacters(in: .whitespaces)
            bookmark.user = bookmark.user.trimmingCharacters(in: .whitespaces)
            verifier.ensureTrusted(host: bookmark.host, port: bookmark.port) { step = .key }
        case .key:
            step = .folders
        case .folders:
            if remoteCount == nil { inspectRemote() } else { step = .schedule }
        case .schedule:
            finish()
        default:
            if let s = Step(rawValue: step.rawValue + 1) { step = s }
        }
    }

    // MARK: steps

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text("Welcome to Burrow").font(.largeTitle.bold())
                Text("Back up a folder of your Mac to an SFTP storage server – automatically, with previous versions kept safely.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("clock.arrow.2.circlepath", .blue, "Automatic backups",
                        "Runs on a schedule, even when the app is closed.")
                feature("archivebox.fill", .orange, "Nothing is lost",
                        "Changed and deleted files are kept in a versions folder on the server.")
                feature("folder.fill", .teal, "Browse your box",
                        "Upload, download and manage files like in the Finder.")
            }
            .frame(maxWidth: 440)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func feature(_ icon: String, _ tint: Color, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: icon, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func header(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.bold())
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isStorageBox {
                header("Where should backups go?",
                       "Enter the login of your Storage Box. You find it in the Hetzner Console under Storage Boxes.")
            } else {
                header("Where should backups go?", "Enter the address and login of your SFTP server.")
            }
            Picker("", selection: $isStorageBox) {
                Text("SFTP server").tag(false)
                Text("Hetzner Storage Box").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .onChange(of: isStorageBox) { _, sb in
                bookmark.port = sb ? 23 : 22
                bookmark.remoteShell = sb
                hasKey = !sb
                if sb { syncStorageBoxHost() }
                else if bookmark.host.hasSuffix(".your-storagebox.de") { bookmark.host = ""; bookmark.name = "" }
            }
            Form {
                if isStorageBox {
                    TextField("Username", text: Binding(get: { bookmark.user },
                                                        set: { bookmark.user = $0; syncStorageBoxHost() }),
                              prompt: Text(verbatim: "u123456"))
                    LabeledContent("Server") {
                        Text(verbatim: bookmark.host.isEmpty ? "—" : "\(bookmark.host) : \(bookmark.port)")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TextField("Server", text: $bookmark.host, prompt: Text(verbatim: "sftp.example.com"))
                    TextField("Port", value: $bookmark.port, format: .number.grouping(.never))
                    TextField("Username", text: $bookmark.user)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: isStorageBox ? 110 : 150)
            if let f = verifier.failure {
                Label(f, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Label("Next, you'll confirm the server's fingerprint so nobody can impersonate it.", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func syncStorageBoxHost() {
        let u = bookmark.user.trimmingCharacters(in: .whitespaces)
        bookmark.host = u.isEmpty ? "" : "\(u).your-storagebox.de"
        bookmark.name = "Storage Box"
    }

    private var key: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Sign in with an SSH key",
                   "Scheduled backups run while nobody is at the Mac, so they log in with a key instead of your password.")
            Picker("", selection: $hasKey) {
                Text("Create a new key").tag(false)
                Text("I already have a key").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .onChange(of: hasKey) { _, _ in keyCheck = nil }

            if !hasKey {
                VStack(alignment: .leading, spacing: 10) {
                    (isStorageBox
                        ? Text("Enter your Storage Box password once. Burrow creates a key and installs it if the box has no existing keys. Otherwise, add the shown public key manually. The password is not stored.")
                        : Text("Enter your account password once. Burrow creates a key and installs it if the server has no existing keys. Otherwise, add the shown public key manually. The password is not stored."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        SecureField("Account password", text: $password).textFieldStyle(.roundedBorder)
                            .onSubmit(installKey)
                        Button("Install Key", action: installKey).disabled(password.isEmpty || model.keySetupBusy)
                    }
                    if isStorageBox {
                        Text("SSH must be enabled for the Storage Box (Hetzner Console → Storage Box → Settings).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .card()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "key.fill").foregroundStyle(.secondary)
                        Text(verbatim: bookmark.keyFile).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { pickKey() }
                    }
                    HStack {
                    Text("The server must accept this key for unattended backups, and the key must have no passphrase.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Check") { checkExistingKey() }.disabled(checkingKey)
                    }
                }
                .card()
            }
            if let r = keyCheck {
                Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(r.ok ? .green : .orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func installKey() {
        guard !password.isEmpty, !model.keySetupBusy else { return }
        bookmark.keyFile = Paths.defaultKey
        keyCheck = nil
        model.installKey(host: bookmark.host, port: bookmark.port, user: bookmark.user,
                         password: password, keyFile: bookmark.keyFile)
        password = ""
    }

    private func checkExistingKey() {
        checkingKey = true
        keyCheck = nil
        let b = bookmark
        Task {
            keyCheck = await model.checkBookmark(b)
            checkingKey = false
        }
    }

    private func pickKey() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.showsHiddenFiles = true
        p.directoryURL = URL(fileURLWithPath: Paths.home + "/.ssh")
        if p.runModal() == .OK, let u = p.url { bookmark.keyFile = u.path; keyCheck = nil }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("What should be backed up?",
                   "Choose a folder on this Mac. It is copied to a folder on the server and kept in sync.")
            HStack(spacing: 12) {
                IconBadge(systemImage: "folder.fill", tint: .blue, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    if cfg.localPath.isEmpty {
                        Text("No folder chosen").font(.headline)
                    } else {
                        Text(verbatim: (cfg.localPath as NSString).lastPathComponent).font(.headline)
                        Text(verbatim: cfg.localPath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Button("Choose…") { pickFolder() }
            }
            .card(padding: 12)
            Form {
                TextField("Backup folder on server", text: Binding(
                    get: { cfg.remotePath },
                    set: { cfg.remotePath = $0; remoteEdited = true; resetInspection() }))
                TextField("Versions folder", text: Binding(
                    get: { cfg.versionsPath }, set: { cfg.versionsPath = $0; resetInspection() }))
            }
            .formStyle(.grouped).scrollDisabled(true).frame(height: 110)
            if let p = cfg.folderProblem {
                Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let e = inspectError {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
            } else if let count = remoteCount, count > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Label("This server folder already contains \(count) items.", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Text("On the first backup, everything in it that isn't in your local folder is moved to the versions folder. The backup folder will then match your Mac exactly.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Toggle("I understand, use this folder", isOn: $acceptNonEmpty)
                }
                .card(tint: .orange, padding: 12)
            } else {
                Text("Files you change or delete on the Mac are moved to the versions folder on the server instead of being overwritten, and kept there for \(cfg.retentionDays) days.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resetInspection() { remoteCount = nil; inspectError = nil; acceptNonEmpty = false }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url else { return }
        cfg.localPath = u.path
        let root = isStorageBox ? "/home/" : ""
        if !remoteEdited { cfg.remotePath = root + u.lastPathComponent; resetInspection() }
        if cfg.versionsPath == AppConfig().versionsPath || cfg.versionsPath == "_versions" {
            cfg.versionsPath = root + "_versions"
        }
    }

    /// Looks at the chosen box folder before the first backup mirrors into it.
    private func inspectRemote() {
        inspecting = true
        inspectError = nil
        let b = bookmark, path = cfg.remotePath.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let n = try await model.remoteItemCount(b, path: path)
                remoteCount = n
                if n == 0 { step = .schedule }
            } catch {
                inspectError = L("Connection failed: %@", error.localizedDescription)
            }
            inspecting = false
        }
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("When should it run?",
                   "The backup runs in the background at this time. If the Mac is asleep or off, it runs as soon as it wakes up.")
            Form {
                Toggle("Automatic backup", isOn: $cfg.scheduleEnabled)
                Picker("Frequency", selection: $cfg.frequency) {
                    Text("Every day").tag(Frequency.daily)
                    Text("Once a week").tag(Frequency.weekly)
                }.disabled(!cfg.scheduleEnabled)
                if cfg.frequency == .weekly {
                    Picker("Day", selection: $cfg.weekday) {
                        ForEach(1...7, id: \.self) { Text(Fmt.weekdays[$0 - 1].capitalized).tag($0) }
                    }.disabled(!cfg.scheduleEnabled)
                }
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).disabled(!cfg.scheduleEnabled)
            }
            .formStyle(.grouped).scrollDisabled(true).frame(height: cfg.frequency == .weekly ? 190 : 150)
            if AccessCheck.isProtected(cfg.localPath) {
                Label("macOS will ask once whether Burrow may read this folder. Choose “Allow” so scheduled backups can read it.",
                      systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func finish() {
        var c = cfg
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        c.hour = comps.hour ?? 21; c.minute = comps.minute ?? 0
        c.remotePath = c.remotePath.trimmingCharacters(in: .whitespaces)
        c.versionsPath = c.versionsPath.trimmingCharacters(in: .whitespaces)
        if bookmark.name.isEmpty { bookmark.name = bookmark.host }
        model.completeOnboarding(bookmark: bookmark, config: c)
        step = .done
    }

    private var done: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("You're all set").font(.largeTitle.bold())
            VStack(spacing: 4) {
                Text(verbatim: "\(cfg.localPath)")
                Image(systemName: "arrow.down").foregroundStyle(.secondary)
                Text(verbatim: "\(bookmark.host):\(cfg.remotePath)")
            }
            .font(.callout.monospaced()).multilineTextAlignment(.center)
            .card(padding: 14).frame(maxWidth: 460)
            Text("We recommend a preview first: it lists what the first backup would upload, without changing anything.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
