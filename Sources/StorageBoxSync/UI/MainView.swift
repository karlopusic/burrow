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
                        Label(b.displayName, systemImage: "server.rack")
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
                    Button { editing = EditingBookmark(bookmark: Bookmark(), isNew: true) } label: {
                        Label("Add Server…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
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
                    } icon: { Image(systemName: "arrow.up.arrow.down") }
                    .tag(SidebarItem.transfers)
                }
                Section("Backup") {
                    Label("Status", systemImage: model.isRunning ? "arrow.triangle.2.circlepath.icloud" : "externaldrive.badge.checkmark")
                        .tag(SidebarItem.backupStatus)
                    Label("Versions", systemImage: "clock.arrow.circlepath").tag(SidebarItem.backupVersions)
                    Label("Backup Settings", systemImage: "gearshape").tag(SidebarItem.backupSettings)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail
        }
        .onAppear { if model.needsSetup && model.bookmarks.isEmpty { selection = .backupSettings } }
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
                Text(t)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if model.toast == t { model.toast = nil } }
                    }
            }
        }
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
            VersionsView().padding(12).navigationTitle(Text("Versions"))
        case .backupSettings:
            SettingsView().navigationTitle(Text("Backup Settings"))
        case .backupStatus, nil:
            OverviewView(openSettings: { selection = .backupSettings }).padding(12).navigationTitle(Text("Backup"))
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
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).bold()
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let actions { actions }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
