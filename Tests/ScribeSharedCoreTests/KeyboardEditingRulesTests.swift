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
        for context in ["looking. fir", "looking! fir", "looking? fir", "looking\nfir"] {
            XCTAssertNil(KeyboardEditingRules.wordBeforeAutocorrectionWord(contextBefore: context))
        }
    }

    func testStandalonePronounCanReachTheCorrectionEngine() {
        for context in ["i", "if i", "then (i"] {
            XCTAssertEqual(KeyboardEditingRules.autocorrectionWord(
                contextBefore: context, fieldKind: .text, autocorrectionEnabled: true
            ), "i")
        }
        for context in ["a", "x", "1i", "item_i", "/i", "@i", "example.i"] {
            XCTAssertNil(KeyboardEditingRules.autocorrectionWord(
                contextBefore: context, fieldKind: .text, autocorrectionEnabled: true
            ))
        }
        for kind in [KeyboardFieldKind.URL, .email, .number, .phone] {
            XCTAssertNil(KeyboardEditingRules.autocorrectionWord(
                contextBefore: "i", fieldKind: kind, autocorrectionEnabled: true
            ))
        }
        XCTAssertNil(KeyboardEditingRules.autocorrectionWord(
            contextBefore: "i", fieldKind: .text, autocorrectionEnabled: false
        ))
        XCTAssertEqual(KeyboardEditingRules.autocorrectionWord(
            contextBefore: "if in is", fieldKind: .text, autocorrectionEnabled: true
        ), "is")
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
        XCTAssertEqual(KeyboardEditingRules.replacement("I", matchingCapitalizationOf: "i"), "I")
        XCTAssertNil(KeyboardEditingRules.replacement("I", matchingCapitalizationOf: "I"))
        XCTAssertNil(KeyboardEditingRules.replacement("Word", matchingCapitalizationOf: "word"))
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
        XCTAssertEqual(
            KeyboardEditingRules.replacement("I'm", matchingCapitalizationOf: "im"),
            "I'm"
        )
        XCTAssertEqual(
            KeyboardEditingRules.replacement("i've", matchingCapitalizationOf: "ive"),
            "I've"
        )
    }

    func testPreferredContractionsRestoreApostrophes() {
        let expected = [
            "dont": "don't",
            "cant": "can't",
            "wont": "won't",
            "im": "I'm",
            "youre": "you're",
            "theyve": "they've",
            "shouldnt": "shouldn't",
        ]
        for (typed, contraction) in expected {
            XCTAssertEqual(
                KeyboardEditingRules.preferredContraction(for: typed),
                contraction
            )
            XCTAssertEqual(
                KeyboardEditingRules.preferredContraction(for: typed.uppercased()),
                contraction
            )
        }
    }

    func testAmbiguousWordsAreNotForcedIntoContractions() {
        for word in ["well", "were", "ill", "its", "lets", "shell", "id"] {
            XCTAssertNil(KeyboardEditingRules.preferredContraction(for: word))
        }
    }

    func testRejectedAutocorrectionWordsUseThePersistedEngineKey() {
        let suiteName = "KeyboardEditingRulesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            ["dont"],
            forKey: KeyboardEditingRules.rejectedAutocorrectionWordsKey
        )
        XCTAssertTrue(
            KeyboardEditingRules.isRejectedAutocorrectionWord(
                "DONT",
                defaults: defaults
            )
        )
        XCTAssertFalse(
            KeyboardEditingRules.isRejectedAutocorrectionWord(
                "cant",
                defaults: defaults
            )
        )
    }

    func testAcceptedSuggestionAdvancesWithASpace() {
        XCTAssertEqual(
            KeyboardEditingRules.acceptedSuggestionText("Suggestion"),
            "Suggestion "
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
        XCTAssertTrue(KeyboardEditingRules.shouldAutomaticallyReplace("dont", with: "don't"))
        XCTAssertFalse(KeyboardEditingRules.shouldAutomaticallyReplace("an", with: "and"))
        XCTAssertFalse(KeyboardEditingRules.shouldAutomaticallyReplace("house", with: "horsepower"))
        XCTAssertFalse(
            KeyboardEditingRules.shouldAutomaticallyReplace("testflight", with: "test-flight")
        )
        XCTAssertFalse(
            KeyboardEditingRules.shouldAutomaticallyReplace("noworry", with: "no-worry")
        )
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
