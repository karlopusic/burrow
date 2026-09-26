import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers

enum BrowserLayout: String { case list, icons }

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @AppStorage("browserLayout") private var layout: BrowserLayout = .list
    @State private var selection = Set<RemoteItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\RemoteItem.name, comparator: .localizedStandard)]
    @State private var dropTargeted = false
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renaming: RemoteItem?
    @State private var renameText = ""
    @State private var infoItem: RemoteItem?
    @State private var confirmPermanent: [RemoteItem]?
    @State private var confirmEmptyTrash = false

    private var selectedItems: [RemoteItem] { model.visibleItems.filter { selection.contains($0.id) } }
    private var sorted: [RemoteItem] {
        let dirs = model.visibleItems.filter(\.isDir).sorted(using: sortOrder)
        let files = model.visibleItems.filter { !$0.isDir }.sorted(using: sortOrder)
        return dirs + files
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            if model.inTrash { trashBar; Divider() }
            content
                .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4) } }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers); return true }
            Divider()
            statusBar
        }
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search in this folder"))
        .onSubmit(of: .search) { model.search() }
        .onChange(of: model.searchText) { _, v in if v.isEmpty { model.clearSearch() } }
        .onChange(of: model.cwd) { _, _ in selection.removeAll() }
        .task { await model.connect() }
        .quickLookPreview($model.quickLookURL)
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { model.newFolder(newFolderName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let r = renaming { model.rename(r, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete permanently?", isPresented: Binding(get: { confirmPermanent != nil }, set: { if !$0 { confirmPermanent = nil } })) {
            Button("Delete Permanently", role: .destructive) { if let s = confirmPermanent { model.deletePermanently(s) } }
        } message: {
            Text("These items will be removed from the server for good. This can't be undone.")
        }
        .confirmationDialog("Empty the trash?", isPresented: $confirmEmptyTrash) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
        } message: {
            Text("Everything in the trash on this server will be deleted for good. This can't be undone.")
        }
        .sheet(item: $infoItem) { InfoSheet(item: $0, model: model) }
    }

    // MARK: toolbar & bars

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack).help("Back").keyboardShortcut("[", modifiers: .command)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward).help("Forward").keyboardShortcut("]", modifiers: .command)
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!model.canGoUp).help("Enclosing folder").keyboardShortcut(.upArrow, modifiers: .command)
        }
        ToolbarItemGroup {
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh").keyboardShortcut("r", modifiers: .command)
            Button { newFolderName = ""; showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .help("New Folder").keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.searchResults != nil)
            Button { chooseUpload() } label: { Image(systemName: "square.and.arrow.up") }
                .help("Upload…").disabled(model.searchResults != nil)
            Button { downloadSelection(ask: false) } label: { Image(systemName: "square.and.arrow.down") }
                .help("Download to Downloads").disabled(selection.isEmpty)
            Button { deleteSelection() } label: { Image(systemName: "trash") }
                .help(model.inTrash ? Text("Delete Permanently") : Text("Move to Trash")).disabled(selection.isEmpty)
            Picker("View", selection: $layout) {
                Image(systemName: "list.bullet").tag(BrowserLayout.list)
                Image(systemName: "square.grid.2x2").tag(BrowserLayout.icons)
            }
            .pickerStyle(.segmented).help("View")
            Menu {
                Toggle("Show Hidden Files", isOn: $model.showHidden)
                Button("Open Trash") { model.openTrash() }
                Divider()
                Button("Paste") { model.paste() }.disabled(model.clipboard == nil)
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Image(systemName: "server.rack").foregroundStyle(.secondary).padding(.trailing, 4)
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { i, crumb in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(crumb.name) { model.open(crumb.path) }
                        .buttonStyle(.borderless)
                        .fontWeight(i == model.breadcrumbs.count - 1 ? .semibold : .regular)
                        .dropDestination(for: URL.self) { urls, _ in
                            model.upload(urls, into: crumb.path, choose: Self.askConflict); return true
                        }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private var trashBar: some View {
        HStack {
            Image(systemName: "trash").foregroundStyle(.orange)
            Text("Trash – deleted items stay here until you empty it. Use “Put Back” to restore them.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Empty Trash…") { confirmEmptyTrash = true }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.loading || model.busy != nil || model.searching || model.pendingOps > 0 { ProgressView().controlSize(.small) }
            if let b = model.busy { Text(b) }
            else if model.searching { Text("Searching…") }
            else if let r = model.searchResults { Text("\(r.count) results") }
            else { Text("\(model.visibleItems.count) items") }
            if !selection.isEmpty { Text("· \(selection.count) selected").foregroundStyle(.secondary) }
            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
                Button { model.error = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
            Spacer()
            if let clip = model.clipboard {
                (clip.cut ? Text("\(clip.items.count) to move") : Text("\(clip.items.count) to copy")).foregroundStyle(.secondary)
                Button("Paste Here") { model.paste() }.controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if model.visibleItems.isEmpty && !model.loading {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: model.searchResults != nil ? "magnifyingglass" : "tray").font(.largeTitle).foregroundStyle(.tertiary)
                (model.searchResults != nil ? Text("Nothing found") : Text("This folder is empty"))
                    .foregroundStyle(.secondary)
                if model.searchResults == nil { Text("Drag files here to upload").font(.callout).foregroundStyle(.tertiary) }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if layout == .list {
            table
        } else {
            grid
        }
    }

    private var table: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    Image(nsImage: item.icon).resizable().frame(width: 16, height: 16)
                    Text(model.searchResults != nil ? item.path : item.name).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn("Modified", value: \.modifiedSort) { item in
                Text(item.modified.map { Fmt.date.string(from: $0) } ?? "—").foregroundStyle(.secondary)
            }.width(min: 120, ideal: 150)
            TableColumn("Size", value: \.size) { item in
                Text(item.isDir ? "—" : Fmt.bytes(item.size)).foregroundStyle(.secondary).monospacedDigit()
            }.width(min: 60, ideal: 80)
            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }.width(min: 80, ideal: 120)
        }
        .contextMenu(forSelectionType: RemoteItem.ID.self) { ids in
            menu(for: model.visibleItems.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let item = model.visibleItems.first(where: { ids.contains($0.id) }) { activate(item) }
        }
        .onKeyPress(.space) { quickLookSelection(); return .handled }
        .onKeyPress(.delete, phases: .down) { press in
            guard press.modifiers.contains(.command), !selection.isEmpty else { return .ignored }
            deleteSelection(); return .handled
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 12) {
                ForEach(sorted) { item in
                    let selected = selection.contains(item.id)
                    VStack(spacing: 4) {
                        Image(nsImage: item.icon).resizable().frame(width: 56, height: 56)
                        Text(item.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .frame(width: 100, height: 96)
                    .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { activate(item) }
                    .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
                        if selected { selection.remove(item.id) } else { selection.insert(item.id) }
                    })
                    .onTapGesture { selection = [item.id] }
                    .contextMenu {
                        let s = selected ? selectedItems : [item]
                        menu(for: s)
                    }
                }
            }
            .padding(12)
        }
        .onKeyPress(.space) { quickLookSelection(); return .handled }
    }

    @ViewBuilder private func menu(for items: [RemoteItem]) -> some View {
        if items.isEmpty {
            Button("New Folder…") { newFolderName = ""; showNewFolder = true }
            Button("Upload…") { chooseUpload() }
            Button("Paste") { model.paste() }.disabled(model.clipboard == nil)
            Button("Refresh") { Task { await model.reload() } }
        } else {
            if items.count == 1, let item = items.first {
                if item.isDir { Button("Open") { activate(item) } } else { Button("Quick Look") { activate(item) } }
            }
            Button("Download") { download(items, ask: false) }
            Button("Download to…") { download(items, ask: true) }
            Divider()
            if model.inTrash {
                Button("Put Back") { model.putBack(items) }.disabled(!items.allSatisfy { model.canPutBack($0) })
                Button("Delete Permanently…", role: .destructive) { confirmPermanent = items }
            } else {
                if items.count == 1, let item = items.first {
                    Button("Rename…") { renameText = item.name; renaming = item }
                }
                Button("Duplicate") { model.duplicate(items) }
                Button("Copy") { model.copy(items) }
                Button("Cut") { model.cut(items) }
                Button("Paste") { model.paste() }.disabled(model.clipboard == nil)
                Divider()
                Button("Move to Trash", role: .destructive) { model.moveToTrash(items) }
            }
            Divider()
            if items.count == 1, let item = items.first {
                Button("Get Info") { infoItem = item }
                Button("Copy Path") { model.copyPath(item) }
                if model.searchResults != nil { Button("Show in Folder") { model.open(RPath.parent(item.path)) } }
            }
        }
    }

    // MARK: actions

    private func activate(_ item: RemoteItem) {
        if item.isDir { model.open(item.path) } else { model.quickLook(item) }
    }

    private func quickLookSelection() {
        if model.quickLookURL != nil { model.quickLookURL = nil; return }
        if let item = selectedItems.first(where: { !$0.isDir }) { model.quickLook(item) }
    }

    private func deleteSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        if model.inTrash { confirmPermanent = items } else { model.moveToTrash(items); selection.removeAll() }
    }

    private func downloadSelection(ask: Bool) { download(selectedItems, ask: ask) }

    private func download(_ items: [RemoteItem], ask: Bool) {
        var folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        if ask {
            let p = NSOpenPanel()
            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.prompt = L("Download Here")
            guard p.runModal() == .OK, let u = p.url else { return }
            folder = u
        }
        model.download(items, to: folder)
    }

    private func chooseUpload() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = true
        p.prompt = L("Upload")
        guard p.runModal() == .OK else { return }
        model.upload(p.urls, choose: Self.askConflict)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let url = URL(dataRepresentation: u, relativeTo: nil) { urls.append(url) }
            }
            model.upload(urls, choose: Self.askConflict)
        }
    }

    /// Cyberduck-style prompt when an upload would hit an existing name. "Replace" keeps the old copy in the trash.
    @MainActor static func askConflict(_ name: String) async -> ConflictChoice {
        let a = NSAlert()
        a.messageText = L("“%@” already exists on the server.", name)
        a.informativeText = L("Replace moves the existing item to the trash first, so nothing is lost.")
        a.addButton(withTitle: L("Keep Both"))
        a.addButton(withTitle: L("Replace"))
        a.addButton(withTitle: L("Skip"))
        switch a.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .replace
        default: return .skip
        }
    }
}

extension RemoteItem {
    var modifiedSort: Date { modified ?? .distantPast }
}

struct InfoSheet: View {
    let item: RemoteItem
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var folderSize: (count: Int, bytes: Int64)?
    @State private var computing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: item.icon).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text(item.name).font(.title3.bold()).lineLimit(2)
                    Text(item.kind).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Server").foregroundStyle(.secondary); Text(model.bookmark.displayName) }
                GridRow { Text("Path").foregroundStyle(.secondary); Text(verbatim: "/" + item.path).textSelection(.enabled) }
                GridRow { Text("Modified").foregroundStyle(.secondary); Text(item.modified.map { Fmt.date.string(from: $0) } ?? "—") }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    if !item.isDir {
                        Text(verbatim: "\(Fmt.bytes(item.size)) (\(item.size.formatted()) B)")
                    } else if let s = folderSize {
                        Text("\(Fmt.bytes(s.bytes)) in \(s.count) files")
                    } else if computing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Calculate") {
                            computing = true
                            Task { folderSize = await model.folderSize(item); computing = false }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 440)
    }
}
