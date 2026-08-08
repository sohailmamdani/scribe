import XCTest
@testable import ScribeSharedCore

final class KeyboardPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "KeyboardPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshStorePreservesExistingKeyboardBehavior() {
        let store = SharedKeyboardPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.preferences, .standard)
        XCTAssertEqual(store.preferences.alternateHoldDelayMilliseconds, 650)
        XCTAssertEqual(store.preferences.symbolPageTapBehavior, .stayOnCurrentPage)
    }

    func testPreferencesRoundTrip() {
        let store = SharedKeyboardPreferencesStore(defaults: defaults)
        let expected = KeyboardPreferences(
            alternateSymbolsEnabled: false,
            alternateHoldDelayMilliseconds: 400,
            symbolPageTapBehavior: .returnToLetters,
            keyPreviewsEnabled: false,
            hapticsEnabled: false,
            doubleSpacePeriodEnabled: false
        )

        store.preferences = expected

        XCTAssertEqual(store.preferences, expected)
    }

    func testDelayIsClampedAtBothEnds() {
        let tooFast = KeyboardPreferences(
            alternateSymbolsEnabled: true,
            alternateHoldDelayMilliseconds: 10,
            symbolPageTapBehavior: .stayOnCurrentPage,
            keyPreviewsEnabled: true,
            hapticsEnabled: true,
            doubleSpacePeriodEnabled: true
        )
        let tooSlow = KeyboardPreferences(
            alternateSymbolsEnabled: true,
            alternateHoldDelayMilliseconds: 9_000,
            symbolPageTapBehavior: .stayOnCurrentPage,
            keyPreviewsEnabled: true,
            hapticsEnabled: true,
            doubleSpacePeriodEnabled: true
        )

        XCTAssertEqual(
            tooFast.alternateHoldDelayMilliseconds,
            KeyboardPreferences.alternateHoldDelayRange.lowerBound
        )
        XCTAssertEqual(
            tooSlow.alternateHoldDelayMilliseconds,
            KeyboardPreferences.alternateHoldDelayRange.upperBound
        )
    }

    func testUnknownSymbolBehaviorFallsBackSafely() {
        defaults.set("future-behavior", forKey: "keyboard.preferences.symbolPageTapBehavior")

        XCTAssertEqual(
            SharedKeyboardPreferencesStore(defaults: defaults).preferences.symbolPageTapBehavior,
            .stayOnCurrentPage
        )
    }

    func testResetRemovesOverrides() {
        let store = SharedKeyboardPreferencesStore(defaults: defaults)
        var changed = KeyboardPreferences.standard
        changed.hapticsEnabled = false
        changed.symbolPageTapBehavior = .returnToLetters
        store.preferences = changed

        store.reset()

        XCTAssertEqual(store.preferences, .standard)
    }
}
