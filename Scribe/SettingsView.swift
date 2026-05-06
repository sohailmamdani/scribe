import SwiftUI
import AppKit
import Carbon

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 460, height: 220)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Picker("Appearance", selection: $prefs.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(20)
    }
}

private struct ShortcutsSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            HStack {
                Text("Toggle recording:")
                HotkeyRecorderField(
                    keyCode: $prefs.hotkeyKeyCode,
                    modifiers: $prefs.hotkeyModifiers
                )
                .frame(width: 180, height: 24)
            }
            Text("Click the field, then press the desired key combination. Requires at least one modifier (⌘, ⌥, ⌃, or ⇧).")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}

struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onCapture = { code, mods in
            self.keyCode = code
            self.modifiers = mods
        }
        view.update(keyCode: keyCode, modifiers: modifiers)
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.update(keyCode: keyCode, modifiers: modifiers)
    }
}

final class HotkeyRecorderNSView: NSView {
    var onCapture: ((UInt32, UInt32) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false {
        didSet { needsDisplay = true; refreshLabel() }
    }
    private var currentKeyCode: UInt32 = 0
    private var currentModifiers: UInt32 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1

        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    func update(keyCode: UInt32, modifiers: UInt32) {
        currentKeyCode = keyCode
        currentModifiers = modifiers
        if !isRecording { refreshLabel() }
    }

    private func refreshLabel() {
        if isRecording {
            label.stringValue = "Press shortcut…"
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = Preferences.describe(keyCode: currentKeyCode, modifiers: currentModifiers)
            label.textColor = .labelColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        let mods = Preferences.carbonModifiers(from: event.modifierFlags)
        guard mods != 0 else {
            NSSound.beep()
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }
        let keyCode = UInt32(event.keyCode)
        currentKeyCode = keyCode
        currentModifiers = mods
        onCapture?(keyCode, mods)
        window?.makeFirstResponder(nil)
    }
}
