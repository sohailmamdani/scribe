import Cocoa
import Carbon

class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callback: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        unregister()
        self.callback = callback

        let hotKeyID = EventHotKeyID(signature: OSType("SCRB".fourCharCodeValue), id: 1)

        if eventHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, _, userData) -> OSStatus in
                    guard let userData = userData else { return noErr }
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                    manager.callback?()
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
        }

        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        print("Registered global hotkey: \(Preferences.describe(keyCode: keyCode, modifiers: modifiers))")
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    deinit {
        unregister()
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}

extension String {
    var fourCharCodeValue: FourCharCode {
        var result: FourCharCode = 0
        if let data = self.data(using: .macOSRoman) {
            data.withUnsafeBytes { bytes in
                for i in 0..<min(4, data.count) {
                    result = (result << 8) + FourCharCode(bytes[i])
                }
            }
        }
        return result
    }
}
