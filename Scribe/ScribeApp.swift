import SwiftUI
import Combine

@main
struct ScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @ObservedObject private var updater = UpdaterController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 600, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var transcriptions: [String] = []
    @Published var statusMessage = "Ready"
    @Published var isLoading = false
    @Published var autoPasteEnabled = true
    @Published var keepOnTop = false
}
