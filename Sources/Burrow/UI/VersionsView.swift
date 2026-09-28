import SwiftUI

struct VersionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: VersionDir?
    @State private var selectedFile: RemoteFile.ID?
    @State private var filter = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Text("Version archive").font(.headline)
                    Spacer()
                    Button { model.loadVersions() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh")
                }
                if model.loadingVersions { ProgressView().frame(maxWidth: .infinity) }
                if model.versions.isEmpty && !model.loadingVersions {
                    ContentUnavailableView {
                        Label("No archived versions yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("When you change or delete a file, the previous copy is kept here for \(model.cfg.retentionDays) days.")
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List(model.versions, selection: $selected) { v in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.date.map { Fmt.date.string(from: $0) } ?? v.name)
                                Text(verbatim: v.name).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "archivebox.fill").foregroundStyle(.orange)
                        }
                        .tag(v)
                    }
                    .listStyle(.sidebar)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(minWidth: 220, maxWidth: 290, maxHeight: .infinity, alignment: .top)
            .padding(.trailing, 8)

            VStack(alignment: .leading, spacing: 8) {
                if let v = selected {
                    HStack {
                        Text("Previous versions from \(v.date.map { Fmt.date.string(from: $0) } ?? v.name)").font(.headline)
                        Spacer()
                        Button {
                            if let f = model.versionFiles.first(where: { $0.id == selectedFile }) { model.restore(version: v, file: f) }
                        } label: { Label("Restore selected", systemImage: "arrow.uturn.backward") }
                        .disabled(selectedFile == nil)
                        Button { model.restore(version: v, file: nil) } label: {
                            Label("Restore all", systemImage: "arrow.uturn.backward.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("Restores go to ~/Downloads/Burrow Restore/ – your working folder is never touched.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Search…", text: $filter).textFieldStyle(.roundedBorder)
                    if model.loadingFiles { ProgressView().frame(maxWidth: .infinity) }
                    Table(model.versionFiles.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) },
                          selection: $selectedFile) {
                        TableColumn("File", value: \.path)
                        TableColumn("Modified", value: \.modTime).width(130)
                        TableColumn("Size") { Text(Fmt.bytes($0.size)) }.width(80)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Select a version on the left", systemImage: "sidebar.left")
                    } description: {
                        Text("Restores go to ~/Downloads/Burrow Restore/ – your working folder is never touched.")
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.leading, 8)
        }
        .onAppear { if model.versions.isEmpty && model.cfg.isComplete { model.loadVersions() } }
        .onChange(of: selected) { _, v in selectedFile = nil; if let v { model.loadFiles(v) } }
    }
}
