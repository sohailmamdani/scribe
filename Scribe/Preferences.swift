import SwiftUI
import Combine
import Carbon
import AppKit

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Keys {
        static let theme = "theme"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
    }

    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }

    @Published var hotkeyKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode) }
    }

    @Published var hotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyModifiers), forKey: Keys.hotkeyModifiers) }
    }

    private init() {
        let defaults = UserDefaults.standard

        let storedTheme = defaults.string(forKey: Keys.theme).flatMap(AppTheme.init(rawValue:))
        self.theme = storedTheme ?? .system

        let storedKey = defaults.object(forKey: Keys.hotkeyKeyCode) as? Int
        self.hotkeyKeyCode = UInt32(storedKey ?? 0x09) // V

        let storedMods = defaults.object(forKey: Keys.hotkeyModifiers) as? Int
        self.hotkeyModifiers = UInt32(storedMods ?? Int(cmdKey | optionKey | controlKey))
    }

    var hotkeyDescription: String {
        Self.describe(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        parts += keyCodeName(keyCode)
        return parts
    }

    private static let keyNames: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x19: "9", 0x1A: "7", 0x1C: "8", 0x1D: "0",
        0x18: "=", 0x1B: "-", 0x1E: "]", 0x21: "[", 0x27: "'", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2F: ".", 0x32: "`",
        0x1F: "O", 0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x28: "K", 0x2D: "N", 0x2E: "M",
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12"
    ]

    private static func keyCodeName(_ code: UInt32) -> String {
        keyNames[code] ?? "Key \(code)"
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }
}
