import SwiftUI
import AppKit
import QuickLook

/// History for one file in the configured backup. Browsing and downloads never replace the live copy.
struct VersionHistorySheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: RemoteItem
    let bookmark: Bookmark
    @State private var previewURL: URL?
    @State private var loadingPreview = false
    @State private var error: String?

    private var archivePath: String? { appModel.archiveRelativePath(item.path, for: bookmark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: item.icon).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading) {
                    Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("Previous versions").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { if let archivePath { appModel.loadHistory(archivePath, force: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh version history").disabled(appModel.historyLoading)
            }
            if appModel.historyLoading { ProgressView("Loading versions…") }
            if let error = appModel.historyError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if !appModel.historyLoading && appModel.historyEntries.isEmpty && appModel.historyError == nil {
                ContentUnavailableView {
                    Label("No archived versions yet", systemImage: "clock.arrow.circlepath")
                }
            }
            List(appModel.historyEntries) { entry in
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.date.map { Fmt.date.string(from: $0) } ?? entry.stamp)
                        Text(Fmt.bytes(entry.size)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Quick Look") { preview(entry, open: false) }
                    Button("Open a copy") { preview(entry, open: true) }
                    Button("Download to…") { chooseDownload(entry) }
                }
                .disabled(loadingPreview)
            }
            .listStyle(.plain)
            HStack {
                Text("These are archived backup copies. Your current file is never replaced.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(18)
        .frame(width: 590, height: 390)
        .quickLookPreview($previewURL)
        .onAppear { if let archivePath { appModel.loadHistory(archivePath) } }
        .onDisappear { appModel.cancelHistory() }
    }

    private func chooseDownload(_ entry: ArchivedFile) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Download Here")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        appModel.downloadArchived(entry, to: folder)
    }

    private func preview(_ entry: ArchivedFile, open: Bool) {
        loadingPreview = true
        error = nil
        let target = BrowserModel.previewCache.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(item.name)
        Task {
            defer { loadingPreview = false }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                _ = try await RcloneDaemon.shared.call("operations/copyfile", [
                    "srcFs": appModel.cfg.versionsRemote, "srcRemote": entry.id,
                    "dstFs": "/", "dstRemote": String(target.path.dropFirst())])
                if open { NSWorkspace.shared.open(target) } else { previewURL = target }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
