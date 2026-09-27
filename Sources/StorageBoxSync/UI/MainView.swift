import SwiftUI

enum SidebarItem: Hashable {
    case server(UUID)
    case transfers
    case backupStatus, backupVersions, backupSettings
}

struct EditingBookmark: Identifiable {
    var id: UUID { bookmark.id }
    var bookmark: Bookmark
    var isNew: Bool
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var transfers = TransferManager.shared
    @State private var selection: SidebarItem? = .backupStatus
    @State private var editing: EditingBookmark?
    @State private var confirmDelete: Bookmark?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Servers") {
                    ForEach(model.bookmarks) { b in
                        Label {
                            HStack {
                                Text(b.displayName)
                                if model.cfg.isBackupServer(b) {
                                    Spacer()
                                    Image(systemName: "externaldrive.fill.badge.timemachine")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .help("Backup destination")
                                }
                            }
                        } icon: {
                            Image(systemName: "server.rack").foregroundStyle(.blue)
                        }
                        .tag(SidebarItem.server(b.id))
                            .contextMenu {
                                Button("Edit…") { editing = EditingBookmark(bookmark: b, isNew: false) }
                                Button("Duplicate") {
                                    var copy = b; copy.id = UUID(); copy.name = b.displayName + " 2"
                                    if b.auth == .password, let pw = Keychain.get(b.id) { Keychain.set(pw, for: copy.id) }
                                    model.saveBookmark(copy)
                                }
                                Divider()
                                Button("Remove…", role: .destructive) { confirmDelete = b }
                            }
                    }
                    if model.bookmarks.isEmpty {
                        Text("No servers yet").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Label {
                        HStack {
                            Text("Transfers")
                            Spacer()
                            if transfers.activeCount > 0 {
                                Text(verbatim: "\(transfers.activeCount)").font(.caption.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                            }
                        }
                    } icon: { Image(systemName: "arrow.up.arrow.down").foregroundStyle(.purple) }
                    .tag(SidebarItem.transfers)
                }
                Section("Backup") {
                    Label {
                        Text("Status")
                    } icon: {
                        Image(systemName: BackupState(model).sidebarIcon).foregroundStyle(BackupState(model).tint)
                    }
                    .tag(SidebarItem.backupStatus)
                    Label { Text("Versions") } icon: { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange) }
                        .tag(SidebarItem.backupVersions)
                    Label { Text("Backup Settings") } icon: { Image(systemName: "gearshape").foregroundStyle(.gray) }
                        .tag(SidebarItem.backupSettings)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Button { editing = EditingBookmark(bookmark: Bookmark(), isNew: true) } label: {
                        Label("Add Server…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .overlay(alignment: .top) { Divider() }
            }
        } detail: {
            detail
        }
        .onAppear { if model.shouldOfferOnboarding { model.showOnboarding = true } }
        .sheet(isPresented: $model.showOnboarding) { OnboardingView().environmentObject(model) }
        .sheet(item: $editing) { e in BookmarkEditor(bookmark: e.bookmark, isNew: e.isNew).environmentObject(model) }
        .confirmationDialog("Remove this server?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Remove", role: .destructive) {
                if let b = confirmDelete {
                    if selection == .server(b.id) { selection = .backupStatus }
                    model.deleteBookmark(b)
                }
            }
        } message: {
            Text("Only the bookmark is removed. Nothing on the server is changed.")
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Toast(text: t)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if model.toast == t { model.toast = nil } }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .server(let id):
            if let b = model.bookmarks.first(where: { $0.id == id }) {
                BrowserView(model: model.browser(for: b))
                    .id(b)                               // fresh view state after the bookmark is edited
                    .navigationTitle(b.displayName)
            }
        case .transfers:
            TransfersView()
        case .backupVersions:
            VersionsView().padding(16).navigationTitle(Text("Versions"))
        case .backupSettings:
            SettingsView().navigationTitle(Text("Backup Settings"))
        case .backupStatus, nil:
            OverviewView(openSettings: { selection = .backupSettings }).navigationTitle(Text("Backup"))
        }
    }
}

struct Banner: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    var actions: AnyView? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: icon, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let actions { actions.padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
        .card(tint: tint, padding: 14)
    }
}
