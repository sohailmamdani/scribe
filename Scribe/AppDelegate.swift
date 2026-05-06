import Cocoa
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyTheme(Preferences.shared.theme)
        Preferences.shared.$theme
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyTheme($0) }
            .store(in: &cancellables)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Scribe")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(UpdaterController.checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = UpdaterController.shared
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Scribe", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    private func applyTheme(_ theme: AppTheme) {
        NSApp.appearance = theme.nsAppearance
    }

    @objc func showWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
