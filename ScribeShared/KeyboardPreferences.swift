import Foundation

enum KeyboardSymbolPageTapBehavior: String, CaseIterable, Identifiable, Sendable {
    case stayOnCurrentPage
    case returnToLetters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stayOnCurrentPage:
            "Stay on symbols"
        case .returnToLetters:
            "Return to letters"
        }
    }
}

enum KeyboardSymbolPageTapScope: String, CaseIterable, Identifiable, Sendable {
    case numbersAndSymbols
    case symbolsOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .numbersAndSymbols:
            "Numbers & symbols"
        case .symbolsOnly:
            "Symbols only"
        }
    }
}

struct KeyboardPreferences: Equatable, Sendable {
    static let alternateHoldDelayRange = 250...1_200
    static let alternateHoldDelayStep = 50

    static let standard = KeyboardPreferences(
        alternateSymbolsEnabled: true,
        alternateHoldDelayMilliseconds: 650,
        symbolPageTapBehavior: .stayOnCurrentPage,
        symbolPageTapScope: .numbersAndSymbols,
        keyPreviewsEnabled: true,
        hapticsEnabled: true,
        doubleSpacePeriodEnabled: true
    )

    var alternateSymbolsEnabled: Bool
    var alternateHoldDelayMilliseconds: Int
    var symbolPageTapBehavior: KeyboardSymbolPageTapBehavior
    var symbolPageTapScope: KeyboardSymbolPageTapScope
    var keyPreviewsEnabled: Bool
    var hapticsEnabled: Bool
    var doubleSpacePeriodEnabled: Bool

    init(
        alternateSymbolsEnabled: Bool,
        alternateHoldDelayMilliseconds: Int,
        symbolPageTapBehavior: KeyboardSymbolPageTapBehavior,
        symbolPageTapScope: KeyboardSymbolPageTapScope,
        keyPreviewsEnabled: Bool,
        hapticsEnabled: Bool,
        doubleSpacePeriodEnabled: Bool
    ) {
        self.alternateSymbolsEnabled = alternateSymbolsEnabled
        self.alternateHoldDelayMilliseconds = min(
            max(alternateHoldDelayMilliseconds, Self.alternateHoldDelayRange.lowerBound),
            Self.alternateHoldDelayRange.upperBound
        )
        self.symbolPageTapBehavior = symbolPageTapBehavior
        self.symbolPageTapScope = symbolPageTapScope
        self.keyPreviewsEnabled = keyPreviewsEnabled
        self.hapticsEnabled = hapticsEnabled
        self.doubleSpacePeriodEnabled = doubleSpacePeriodEnabled
    }
}

/// Preferences shared by the containing app and keyboard extension.
///
/// Each value has its own key rather than encoding one settings blob. That
/// keeps future additions backward compatible: an older build can ignore a
/// new key, and a newer build supplies the current default for a missing key.
struct SharedKeyboardPreferencesStore: @unchecked Sendable {
    private enum Key {
        static let alternateSymbolsEnabled = "keyboard.preferences.alternateSymbolsEnabled"
        static let alternateHoldDelayMilliseconds = "keyboard.preferences.alternateHoldDelayMilliseconds"
        static let symbolPageTapBehavior = "keyboard.preferences.symbolPageTapBehavior"
        static let symbolPageTapScope = "keyboard.preferences.symbolPageTapScope"
        static let keyPreviewsEnabled = "keyboard.preferences.keyPreviewsEnabled"
        static let hapticsEnabled = "keyboard.preferences.hapticsEnabled"
        static let doubleSpacePeriodEnabled = "keyboard.preferences.doubleSpacePeriodEnabled"

        static let all = [
            alternateSymbolsEnabled,
            alternateHoldDelayMilliseconds,
            symbolPageTapBehavior,
            symbolPageTapScope,
            keyPreviewsEnabled,
            hapticsEnabled,
            doubleSpacePeriodEnabled,
        ]
    }

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: SharedDictationStore.appGroupIdentifier)) {
        self.defaults = defaults
    }

    var preferences: KeyboardPreferences {
        get {
            let fallback = KeyboardPreferences.standard
            let storedDelay = defaults?.object(forKey: Key.alternateHoldDelayMilliseconds) == nil
                ? fallback.alternateHoldDelayMilliseconds
                : defaults?.integer(forKey: Key.alternateHoldDelayMilliseconds)
                    ?? fallback.alternateHoldDelayMilliseconds
            let behavior = defaults?.string(forKey: Key.symbolPageTapBehavior)
                .flatMap(KeyboardSymbolPageTapBehavior.init(rawValue:))
                ?? fallback.symbolPageTapBehavior
            let scope = defaults?.string(forKey: Key.symbolPageTapScope)
                .flatMap(KeyboardSymbolPageTapScope.init(rawValue:))
                ?? fallback.symbolPageTapScope

            return KeyboardPreferences(
                alternateSymbolsEnabled: bool(
                    forKey: Key.alternateSymbolsEnabled,
                    fallback: fallback.alternateSymbolsEnabled
                ),
                alternateHoldDelayMilliseconds: storedDelay,
                symbolPageTapBehavior: behavior,
                symbolPageTapScope: scope,
                keyPreviewsEnabled: bool(
                    forKey: Key.keyPreviewsEnabled,
                    fallback: fallback.keyPreviewsEnabled
                ),
                hapticsEnabled: bool(
                    forKey: Key.hapticsEnabled,
                    fallback: fallback.hapticsEnabled
                ),
                doubleSpacePeriodEnabled: bool(
                    forKey: Key.doubleSpacePeriodEnabled,
                    fallback: fallback.doubleSpacePeriodEnabled
                )
            )
        }
        nonmutating set {
            let normalized = KeyboardPreferences(
                alternateSymbolsEnabled: newValue.alternateSymbolsEnabled,
                alternateHoldDelayMilliseconds: newValue.alternateHoldDelayMilliseconds,
                symbolPageTapBehavior: newValue.symbolPageTapBehavior,
                symbolPageTapScope: newValue.symbolPageTapScope,
                keyPreviewsEnabled: newValue.keyPreviewsEnabled,
                hapticsEnabled: newValue.hapticsEnabled,
                doubleSpacePeriodEnabled: newValue.doubleSpacePeriodEnabled
            )
            defaults?.set(normalized.alternateSymbolsEnabled, forKey: Key.alternateSymbolsEnabled)
            defaults?.set(
                normalized.alternateHoldDelayMilliseconds,
                forKey: Key.alternateHoldDelayMilliseconds
            )
            defaults?.set(normalized.symbolPageTapBehavior.rawValue, forKey: Key.symbolPageTapBehavior)
            defaults?.set(normalized.symbolPageTapScope.rawValue, forKey: Key.symbolPageTapScope)
            defaults?.set(normalized.keyPreviewsEnabled, forKey: Key.keyPreviewsEnabled)
            defaults?.set(normalized.hapticsEnabled, forKey: Key.hapticsEnabled)
            defaults?.set(normalized.doubleSpacePeriodEnabled, forKey: Key.doubleSpacePeriodEnabled)
        }
    }

    func reset() {
        for key in Key.all {
            defaults?.removeObject(forKey: key)
        }
    }

    private func bool(forKey key: String, fallback: Bool) -> Bool {
        guard defaults?.object(forKey: key) != nil else { return fallback }
        return defaults?.bool(forKey: key) ?? fallback
    }
}
