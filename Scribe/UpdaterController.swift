import Foundation
import Sparkle
import Combine

final class UpdaterController: NSObject, ObservableObject {
    static let shared = UpdaterController()

    let updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

    private override init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    @objc func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
