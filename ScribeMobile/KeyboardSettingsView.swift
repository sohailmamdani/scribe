import SwiftUI

struct KeyboardSettingsView: View {
    private let store: SharedKeyboardPreferencesStore
    @State private var preferences: KeyboardPreferences

    init(store: SharedKeyboardPreferencesStore = SharedKeyboardPreferencesStore()) {
        self.store = store
        _preferences = State(initialValue: store.preferences)
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Alternate symbols",
                    isOn: binding(\.alternateSymbolsEnabled)
                )

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Long-press delay")
                        Spacer()
                        Text(delayLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: delayBinding,
                        in: Double(KeyboardPreferences.alternateHoldDelayRange.lowerBound)...Double(
                            KeyboardPreferences.alternateHoldDelayRange.upperBound
                        ),
                        step: Double(KeyboardPreferences.alternateHoldDelayStep)
                    )
                    .disabled(!preferences.alternateSymbolsEnabled)
                    .accessibilityValue(delayLabel)
                }

                Picker(
                    "After tapping a symbol",
                    selection: binding(\.symbolPageTapBehavior)
                ) {
                    ForEach(KeyboardSymbolPageTapBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }

                Picker(
                    "Apply to",
                    selection: binding(\.symbolPageTapScope)
                ) {
                    ForEach(KeyboardSymbolPageTapScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
            } header: {
                Text("Symbols")
            } footer: {
                Text("Choose whether digits and symbols return to letters, or only symbols while 0–9 keep the 123 page open.")
            }

            Section("Typing") {
                Toggle("Key pop-up previews", isOn: binding(\.keyPreviewsEnabled))
                Toggle("Double-space period", isOn: binding(\.doubleSpacePeriodEnabled))
            }

            Section {
                Toggle("Keyboard haptics", isOn: binding(\.hapticsEnabled))
            } footer: {
                Text("Changes are picked up when the Scribe keyboard next becomes active.")
            }

            Section {
                Button("Restore Keyboard Defaults", role: .destructive) {
                    store.reset()
                    preferences = .standard
                }
            }
        }
        .navigationTitle("Keyboard Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var delayLabel: String {
        String(format: "%.2f s", Double(preferences.alternateHoldDelayMilliseconds) / 1_000)
    }

    private var delayBinding: Binding<Double> {
        Binding(
            get: { Double(preferences.alternateHoldDelayMilliseconds) },
            set: { value in
                preferences.alternateHoldDelayMilliseconds = Int(value.rounded())
                persist()
            }
        )
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<KeyboardPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { value in
                preferences[keyPath: keyPath] = value
                persist()
            }
        )
    }

    private func persist() {
        store.preferences = preferences
    }
}
