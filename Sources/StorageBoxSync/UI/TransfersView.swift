import SwiftUI
import AppKit

struct TransfersView: View {
    @ObservedObject var manager = TransferManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if manager.items.isEmpty {
                ContentUnavailableView {
                    Label("No transfers yet", systemImage: "arrow.up.arrow.down.circle")
                } description: {
                    Text("Drag files into a server folder to upload, or right-click a file to download it.")
                }
            } else {
                List(manager.items) { t in TransferRow(t: t) }
                    .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(manager.activeCount) active").foregroundStyle(.secondary)
                Spacer()
                Button("Clear Finished") { manager.clearFinished() }
                    .disabled(!manager.items.contains { [.done, .failed, .cancelled].contains($0.state) })
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .navigationTitle(Text("Transfers"))
    }
}

struct TransferRow: View {
    let t: Transfer
    private var manager: TransferManager { .shared }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: icon, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(t.name).bold().lineLimit(1).truncationMode(.middle)
                    if t.isDir { Image(systemName: "folder").foregroundStyle(.secondary) }
                }
                Text(verbatim: "→ \(t.destLabel)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if t.state == .running {
                    if let f = t.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                }
                detail.font(.caption).foregroundStyle(t.state == .failed ? Color.orange : Color.secondary).lineLimit(2)
            }
            Spacer()
            buttons
        }
        .padding(.vertical, 4)
    }

    private var detail: Text {
        switch t.state {
        case .queued: return Text("Waiting…")
        case .running:
            var s = "\(Fmt.bytes(t.bytes))"
            if t.totalBytes > 0 { s += " / \(Fmt.bytes(t.totalBytes))" }
            if t.speed > 0 { s += " · \(Fmt.bytes(Int64(t.speed)))/s" }
            if let eta = t.eta, eta > 0 { s += " · " + (Fmt.remaining(eta) ?? "") }
            if t.isDir && t.totalFiles > 0 { s += " · \(t.files)/\(t.totalFiles)" }
            return Text(verbatim: s)
        case .paused: return Text("Paused")
        case .done:
            let when = t.finished.map { Fmt.date.string(from: $0) } ?? ""
            return Text("Done · \(Fmt.bytes(t.totalBytes)) · \(when)")
        case .failed: return Text(t.error ?? L("Failed"))
        case .cancelled: return Text("Cancelled")
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 6) {
            switch t.state {
            case .running, .queued:
                Button { manager.pause(t.id) } label: { Image(systemName: "pause.circle") }.help("Pause")
                Button { manager.cancel(t.id) } label: { Image(systemName: "xmark.circle") }.help("Cancel")
            case .paused:
                Button { manager.resume(t.id) } label: { Image(systemName: "play.circle") }.help("Resume")
                Button { manager.cancel(t.id) } label: { Image(systemName: "xmark.circle") }.help("Cancel")
            case .failed, .cancelled:
                Button { manager.resume(t.id) } label: { Image(systemName: "arrow.clockwise.circle") }.help("Retry")
                    .disabled(t.srcFs.isEmpty)   // restored from history: endpoints are not persisted
            case .done:
                if t.kind == .download {
                    Button { reveal() } label: { Image(systemName: "magnifyingglass.circle") }.help("Show in Finder")
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }

    private func reveal() {
        let path = t.destLabel.replacingOccurrences(of: "~", with: Paths.home, options: .anchored)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private var icon: String {
        switch t.kind {
        case .upload: return "arrow.up"
        case .download: return "arrow.down"
        case .copy: return "doc.on.doc.fill"
        }
    }

    private var tint: Color {
        switch t.state {
        case .done: return .green
        case .failed: return .orange
        case .cancelled, .paused: return .gray
        default: return .accentColor
        }
    }
}
