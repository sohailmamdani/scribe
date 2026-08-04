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

    func testAutocorrectionExtractsTheWordAtTheCursor() {
        XCTAssertEqual(
            KeyboardEditingRules.autocorrectionWord(
                contextBefore: "Please type teh",
                fieldKind: .text,
                autocorrectionEnabled: true
            ),
            "teh"
        )
        XCTAssertEqual(
            KeyboardEditingRules.autocorrectionWord(
                contextBefore: "That isn’t",
                fieldKind: .text,
                autocorrectionEnabled: true
            ),
            "isn’t"
        )
    }

    func testAutocorrectionExtractsThePreviousContextWord() {
        XCTAssertEqual(
            KeyboardEditingRules.wordBeforeAutocorrectionWord(
                contextBefore: "Please type teh"
            ),
            "type"
        )
        XCTAssertEqual(
            KeyboardEditingRules.wordBeforeAutocorrectionWord(
                contextBefore: "Thank-you, teh"
            ),
            "you"
        )
        XCTAssertNil(
            KeyboardEditingRules.wordBeforeAutocorrectionWord(contextBefore: "teh")
        )
    }

    func testAutocorrectionRespectsHostTraitsAndFieldKind() {
        XCTAssertNil(
            KeyboardEditingRules.autocorrectionWord(
                contextBefore: "teh",
                fieldKind: .URL,
                autocorrectionEnabled: true
            )
        )
        XCTAssertNil(
            KeyboardEditingRules.autocorrectionWord(
                contextBefore: "teh",
                fieldKind: .text,
                autocorrectionEnabled: false
            )
        )
        XCTAssertNil(
            KeyboardEditingRules.autocorrectionWord(
                contextBefore: "NASA",
                fieldKind: .text,
                autocorrectionEnabled: true
            )
        )
    }

    func testAutocorrectionPreservesTypedCapitalization() {
        XCTAssertEqual(
            KeyboardEditingRules.replacement("the", matchingCapitalizationOf: "Teh"),
            "The"
        )
        XCTAssertEqual(
            KeyboardEditingRules.replacement("The", matchingCapitalizationOf: "teh"),
            "the"
        )
        XCTAssertNil(
            KeyboardEditingRules.replacement("teh", matchingCapitalizationOf: "teh")
        )
    }

    func testCorrectionDistanceTreatsAdjacentTranspositionAsOneEdit() {
        XCTAssertEqual(KeyboardEditingRules.correctionDistance("teh", "the"), 1)
        XCTAssertEqual(KeyboardEditingRules.correctionDistance("watre", "water"), 1)
        XCTAssertEqual(KeyboardEditingRules.correctionDistance("keyboard", "cupboard"), 3)
    }

    func testAutomaticCorrectionOnlyCommitsCloseTypos() {
        XCTAssertTrue(KeyboardEditingRules.shouldAutomaticallyReplace("teh", with: "the"))
        XCTAssertTrue(KeyboardEditingRules.shouldAutomaticallyReplace("hellp", with: "hello"))
        XCTAssertFalse(KeyboardEditingRules.shouldAutomaticallyReplace("an", with: "and"))
        XCTAssertFalse(KeyboardEditingRules.shouldAutomaticallyReplace("house", with: "horsepower"))
    }

    func testCorrectionCandidatesAreDeduplicatedAndRejectWildGuesses() {
        let ranked = KeyboardEditingRules.rankedCorrectionSuggestions(
            for: "teh",
            suggestions: ["tech", "the", "The", "keyboard"],
            frequencyRanks: ["the": 1, "tech": 800]
        )
        XCTAssertEqual(ranked, ["the", "tech"])
    }
}
