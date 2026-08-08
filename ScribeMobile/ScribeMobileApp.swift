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
                    // Claim and acknowledge the keyboard request before model
                    // loading so a cold launch never looks like a lost tap.
                    let handledKeyboardRequest = await coordinator.handlePendingKeyboardRequest()
                    if !handledKeyboardRequest {
                        await coordinator.prepareModel()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    Task {
                        let handledKeyboardRequest = await coordinator.handlePendingKeyboardRequest()
                        if !handledKeyboardRequest {
                            // A CPU fallback is scoped to the live background
                            // session. Returning to Scribe restores Large-v3.
                            await coordinator.prepareModel()
                        }
                    }
                }
        }
    }
}
