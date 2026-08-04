import XCTest
@testable import ScribeSharedCore

final class KeyboardEditingRulesTests: XCTestCase {
    func testDoubleSpaceAfterAWordBecomesPeriod() {
        XCTAssertTrue(
            KeyboardEditingRules.shouldConvertDoubleSpace(
                contextBefore: "Hello ",
                elapsedSincePreviousSpace: 0.2,
                fieldKind: .text
            )
        )
    }

    func testDoubleSpaceDoesNotFireAfterTimeoutOrPunctuation() {
        XCTAssertFalse(
            KeyboardEditingRules.shouldConvertDoubleSpace(
                contextBefore: "Hello ",
                elapsedSincePreviousSpace: 0.8,
                fieldKind: .text
            )
        )
        XCTAssertFalse(
            KeyboardEditingRules.shouldConvertDoubleSpace(
                contextBefore: "Hello. ",
                elapsedSincePreviousSpace: 0.2,
                fieldKind: .text
            )
        )
    }

    func testDoubleSpaceIsDisabledForURLsAndEmails() {
        for fieldKind in [KeyboardFieldKind.URL, .email, .webSearch] {
            XCTAssertFalse(
                KeyboardEditingRules.shouldConvertDoubleSpace(
                    contextBefore: "example ",
                    elapsedSincePreviousSpace: 0.2,
                    fieldKind: fieldKind
                )
            )
        }
    }

    func testSentenceCapitalizationTracksContext() {
        XCTAssertEqual(
            KeyboardEditingRules.automaticShiftState(
                contextBefore: "",
                capitalization: .sentences
            ),
            .once
        )
        XCTAssertEqual(
            KeyboardEditingRules.automaticShiftState(
                contextBefore: "Hello. ",
                capitalization: .sentences
            ),
            .once
        )
        XCTAssertEqual(
            KeyboardEditingRules.automaticShiftState(
                contextBefore: "Hello ",
                capitalization: .sentences
            ),
            .off
        )
    }

    func testAllCharactersUsesLockedShift() {
        XCTAssertEqual(
            KeyboardEditingRules.automaticShiftState(
                contextBefore: "anything",
                capitalization: .allCharacters
            ),
            .locked
        )
    }
}
