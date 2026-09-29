import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        let headless = ["--run", "--dry-run", "--check-access", "--selftest", "--version"].contains { args.contains($0) }
        if !headless { RenameMigration.migrateDefaults() }   // before the language is applied
        AppLanguage.apply()
        if args.contains("--version") {
            print(AppInfo.version)
            return
        }
        if args.contains("--check-access") {
            exit(AccessCheck.probe())
        }
        if args.contains("--run") || args.contains("--dry-run") {
            exit(Runner.main(args: args))
        }
        if let i = args.firstIndex(of: "--selftest") {
            let rest = Array(args[(i + 1)...])
            Task { @MainActor in exit(await SelfTest.run(rest)) }
            RunLoop.main.run()   // timers (transfer polling) need a running main run loop
        }
        BurrowApp.main()
    }
}

/// Quitting ends the rclone daemon and with it every upload and download, so ask first while any are active.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = MainActor.assumeIsolated { TransferManager.shared.activeCount }
        guard active > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Transfers in progress")
        alert.informativeText = L("Quitting stops the active uploads and downloads (%ld). Unfinished files are not completed.", active)
        alert.addButton(withTitle: L("Quit Anyway"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct BurrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = UpdateController()

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            MainView().environmentObject(model).environmentObject(updater)
                .frame(minWidth: 840, minHeight: 620)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent().environmentObject(model).environmentObject(updater)
        } label: {
            Image(systemName: menuIcon)
        }
    }

    private var menuIcon: String { BackupState(model).menuBarIcon }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isRunning {
            (model.status.running?.dryRun == true ? Text("Preview in progress…") : Text("Backup in progress…"))
            if let p = model.progress, !p.bytesLine.isEmpty { Text(p.bytesLine) }
            Button("Stop") { model.stop() }
        } else {
            if let e = model.status.lastSuccess?.end {
                Text("Last backup: \(Fmt.relative.localizedString(for: e, relativeTo: Date()))")
            } else {
                Text("No successful backup yet")
            }
            if let n = model.cfg.nextRun(), model.cfg.isComplete {
                Text("Next backup: \(Fmt.dayTime.string(from: n))")
            }
            Button("Back up now") { model.startBackup() }.disabled(model.needsSetup)
            Button("Preview changes") { model.startDryRun() }.disabled(model.needsSetup)
        }
        Divider()
        if updater.canCheck { Button("Check for Updates…") { updater.checkForUpdates() } }
        Button("Open \(AppInfo.name)") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
