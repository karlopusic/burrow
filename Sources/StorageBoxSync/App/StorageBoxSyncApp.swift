import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--run") || args.contains("--dry-run") {
            exit(Runner.main(args: args))
        }
        StorageBoxSyncApp.main()
    }
}

struct StorageBoxSyncApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            MainView().environmentObject(model)
                .frame(minWidth: 840, minHeight: 620)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: menuIcon)
        }
    }

    private var menuIcon: String {
        if model.isRunning { return "arrow.triangle.2.circlepath.icloud" }
        switch model.status.lastBackup?.result {
        case .ok?, nil: return "externaldrive.badge.checkmark"
        default: return "externaldrive.badge.exclamationmark"
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isRunning {
            (model.status.running?.dryRun == true ? Text("Preview in progress…") : Text("Backup in progress…"))
            if let p = model.progress, !p.bytesLine.isEmpty { Text(p.bytesLine) }
            Button("Stop") { model.stop() }
        } else if let e = model.status.lastSuccess?.end {
            Text("Last backup: \(Fmt.relative.localizedString(for: e, relativeTo: Date()))")
            Button("Back up now") { model.startBackup() }
        } else {
            Text("No successful backup yet")
            Button("Back up now") { model.startBackup() }.disabled(model.needsSetup)
        }
        Divider()
        Button("Open \(AppInfo.name)") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
