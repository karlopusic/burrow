import Foundation
import Sparkle

/// Sparkle checks the signed appcast automatically and presents the standard install flow.
@MainActor
final class UpdateController: ObservableObject {
    private let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                          updaterDelegate: nil,
                                                          userDriverDelegate: nil)

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
