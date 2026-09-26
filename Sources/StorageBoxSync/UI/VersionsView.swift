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
                    Button { model.loadVersions() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }
                if model.loadingVersions { ProgressView().frame(maxWidth: .infinity) }
                List(model.versions, selection: $selected) { v in
                    VStack(alignment: .leading) {
                        Text(v.date.map { Fmt.date.string(from: $0) } ?? v.name)
                        Text(verbatim: v.name).font(.caption).foregroundStyle(.secondary)
                    }.tag(v)
                }
                if model.versions.isEmpty && !model.loadingVersions {
                    Text("No archived versions yet. When you change or delete a file, the previous copy is kept here for \(model.cfg.retentionDays) days.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 220, maxWidth: 290)
            .padding(.trailing, 8)

            VStack(alignment: .leading, spacing: 8) {
                if let v = selected {
                    HStack {
                        Text("Previous versions from \(v.date.map { Fmt.date.string(from: $0) } ?? v.name)").font(.headline)
                        Spacer()
                        Button("Restore selected") {
                            if let f = model.versionFiles.first(where: { $0.id == selectedFile }) { model.restore(version: v, file: f) }
                        }.disabled(selectedFile == nil)
                        Button("Restore all") { model.restore(version: v, file: nil) }
                    }
                    Text("Restores go to ~/Downloads/StorageBox Sync Restore/ – your working folder is never touched.")
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
                    Spacer()
                    Text("Select a version on the left").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(.leading, 8)
        }
        .onAppear { if model.versions.isEmpty && model.cfg.isComplete { model.loadVersions() } }
        .onChange(of: selected) { _, v in selectedFile = nil; if let v { model.loadFiles(v) } }
    }
}
