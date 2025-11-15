import Cocoa
import ApplicationServices

class AutoPaste {
    var isEnabled: Bool = true
    private var previousClipboard: String?

    func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func paste(_ text: String) {
        guard isEnabled else { return }

        // Save current clipboard if we want to restore it
        previousClipboard = NSPasteboard.general.string(forType: .string)

        // Set text to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Small delay to ensure clipboard is set
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            // Simulate Cmd+V
            self?.simulatePaste()

            // Restore clipboard after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let previous = self?.previousClipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(previous, forType: .string)
                }
            }
        }
    }

    private func simulatePaste() {
        // Create Cmd+V key event
        let source = CGEventSource(stateID: .combinedSessionState)

        // Key down for 'v' with Command modifier
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0x09, // 'v' key code
            keyDown: true
        )
        keyDown?.flags = .maskCommand

        // Key up for 'v'
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0x09,
            keyDown: false
        )
        keyUp?.flags = .maskCommand

        // Post events
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
