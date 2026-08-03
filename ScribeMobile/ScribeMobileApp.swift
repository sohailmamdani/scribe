import SwiftUI

@main
struct ScribeMobileApp: App {
    @StateObject private var coordinator = DictationCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileContentView(coordinator: coordinator)
                .onOpenURL { url in
                    Task { await coordinator.handle(url: url) }
                }
                .task {
                    await coordinator.prepareModel()
                    await coordinator.handlePendingKeyboardCommand()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    Task { await coordinator.handlePendingKeyboardCommand() }
                }
        }
    }
}
