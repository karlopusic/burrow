import Foundation
import Sparkle

/// Sparkle checks the signed appcast automatically and presents the standard install flow.
/// Development builds (started from the repository's build folder) don't check: they aren't a published release,
/// and an update would replace the build with an unrelated download.
@MainActor
final class UpdateController: ObservableObject {
    static var isEnabled: Bool {
        !Install.isDevelopmentBuild && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    private let controller = SPUStandardUpdaterController(startingUpdater: UpdateController.isEnabled,
                                                          updaterDelegate: nil,
                                                          userDriverDelegate: nil)

    var canCheck: Bool { Self.isEnabled }

    func checkForUpdates() {
        guard canCheck else { return }
        controller.checkForUpdates(nil)
    }
}
