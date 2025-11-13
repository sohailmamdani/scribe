import Cocoa
import Carbon

enum HotkeyKey: UInt32 {
    case v = 0x09
    case r = 0x0F
    case space = 0x31
}

struct HotkeyModifiers: OptionSet {
    let rawValue: UInt32

    static let command = HotkeyModifiers(rawValue: UInt32(cmdKey))
    static let option = HotkeyModifiers(rawValue: UInt32(optionKey))
    static let control = HotkeyModifiers(rawValue: UInt32(controlKey))
    static let shift = HotkeyModifiers(rawValue: UInt32(shiftKey))
}

class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyID = EventHotKeyID()
    private var callback: (() -> Void)?
    private var eventHandler: EventHandlerRef?

    func register(
        key: HotkeyKey,
        modifiers: HotkeyModifiers,
        callback: @escaping () -> Void
    ) {
        self.callback = callback

        // Create hotkey ID
        hotKeyID.signature = OSType("SCRB".fourCharCodeValue)
        hotKeyID.id = 1

        // Convert modifiers
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }
        if modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }
        if modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }

        // Register event handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (nextHandler, theEvent, userData) -> OSStatus in
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

        // Register hotkey
        RegisterEventHotKey(
            key.rawValue,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        print("Registered global hotkey: ⌘⌥⌃V")
    }

    deinit {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}

// Helper extension for FourCharCode
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
