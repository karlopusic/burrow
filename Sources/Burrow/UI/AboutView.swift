import SwiftUI
import AppKit

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var updater: UpdateController

    var body: some View {
        VStack(spacing: 15) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 88, height: 88)
            VStack(spacing: 4) {
                Text(AppInfo.name).font(.title.bold())
                Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
            }
            Divider()
            VStack(spacing: 4) {
                Text("Made by PUSH").font(.headline)
                Text(verbatim: "Naselje kralja Zvonimira 2/3 · 43000 Bjelovar, Croatia")
                Text(verbatim: "OIB/VAT: HR40332290472")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Link("push.hr", destination: URL(string: "https://push.hr")!)
            Link("karlo@push.hr", destination: URL(string: "mailto:karlo@push.hr")!)
            Text("Open source under the MIT License. Includes rclone and Sparkle.")
                .font(.caption).foregroundStyle(.secondary)
            if updater.canCheck {
                Button("Check for Updates…") { updater.checkForUpdates() }
            } else {
                Text("Development build – updates are off.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Close") { dismiss() }
        }
        .frame(width: 440)
        .padding(24)
    }
}
