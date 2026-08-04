import XCTest
@testable import ScribeSharedCore

final class KeyboardCorrectionRankingTests: XCTestCase {
    private func candidate(
        _ word: String,
        distance: Int = 1,
        frequency: Int64 = 5_000_000,
        bigramFrequency: Int64 = 0,
        systemRank: Int? = 0,
        spatialCost: Double = 0.3,
        acceptedCount: Int = 0
    ) -> KeyboardCorrectionCandidate {
        KeyboardCorrectionCandidate(
            word: word,
            distance: distance,
            frequency: frequency,
            bigramFrequency: bigramFrequency,
            systemRank: systemRank,
            spatialCost: spatialCost,
            acceptedCount: acceptedCount
        )
    }

    // MARK: - The autocorrect regression

    /// The old gate demanded the winner also be `UITextChecker`'s *first*
    /// guess. Because ranking weighs frequency, bigrams, and touch evidence,
    /// the winner usually is not — so automatic correction almost never fired.
    /// A confident winner must now commit regardless of where the system
    /// spell checker happened to rank it.
    func testWinnerAutoReplacesEvenWhenItIsNotTheSystemsFirstGuess() {
        let ranked = KeyboardCorrectionRanking.rank([
            candidate("the", frequency: 23_135_851_162, systemRank: 3),
            candidate("tea", distance: 2, frequency: 90_000, systemRank: 0),
        ])
        XCTAssertEqual(ranked.first?.word, "the")
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "teh",
                originalIsKnownWord: false,
                isProtected: false,
                ranked: ranked
            ),
            .autoReplace
        )
    }

    func testClearSingleEditWinnerAutoReplaces() {
        let ranked = KeyboardCorrectionRanking.rank([candidate("receive")])
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "recieve",
                originalIsKnownWord: false,
                isProtected: false,
                ranked: ranked
            ),
            .autoReplace
        )
    }

    // MARK: - Restraint

    /// Two near-equal candidates must not commit themselves. This is the guard
    /// against confident wrong replacements.
    func testAmbiguousWinnerOnlySuggests() {
        let ranked = KeyboardCorrectionRanking.rank([
            candidate("form", frequency: 1_000_000, spatialCost: 0.4),
            candidate("fort", frequency: 1_000_000, spatialCost: 0.4),
        ])
        let margin = KeyboardCorrectionRanking.score(ranked[1])
            - KeyboardCorrectionRanking.score(ranked[0])
        XCTAssertLessThan(margin, KeyboardCorrectionRanking.autoReplaceMargin)
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "forn",
                originalIsKnownWord: false,
                isProtected: false,
                ranked: ranked
            ),
            .suggest
        )
    }

    /// Never overwrite a word that is spelled correctly — the behaviour people
    /// describe as the keyboard fighting them.
    func testKnownWordsAreNeverAutomaticallyReplaced() {
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "well",
                originalIsKnownWord: true,
                isProtected: false,
                ranked: KeyboardCorrectionRanking.rank([candidate("we'll")])
            ),
            .suggest
        )
    }

    func testRejectedWordsOfferNothing() {
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "brb",
                originalIsKnownWord: false,
                isProtected: true,
                ranked: KeyboardCorrectionRanking.rank([candidate("bra")])
            ),
            .none
        )
    }

    func testNoCandidatesMeansNoCorrection() {
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "qqqq",
                originalIsKnownWord: false,
                isProtected: false,
                ranked: []
            ),
            .none
        )
    }

    /// Very short words stay hands-off: at three characters almost any edit
    /// produces a different word rather than a repair.
    func testTwoCharacterWordsAreNotAutomaticallyReplaced() {
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "im",
                originalIsKnownWord: false,
                isProtected: false,
                ranked: KeyboardCorrectionRanking.rank([candidate("in")])
            ),
            .suggest
        )
    }

    // MARK: - Two-edit corrections

    /// "definately" → "definitely" is two edits and is exactly what users
    /// expect to be fixed. The old rule capped automatic correction at one.
    func testLongWordsAutoReplaceAcrossTwoEditsWithGoodEvidence() {
        let ranked = KeyboardCorrectionRanking.rank([
            candidate(
                "definitely",
                distance: 2,
                frequency: 40_000_000,
                bigramFrequency: 900_000,
                systemRank: 0,
                spatialCost: 0.5
            ),
        ])
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "definately",
                originalIsKnownWord: false,
                isProtected: false,
                ranked: ranked
            ),
            .autoReplace
        )
    }

    func testShortWordsDoNotAutoReplaceAcrossTwoEdits() {
        let ranked = KeyboardCorrectionRanking.rank([
            candidate("card", distance: 2, systemRank: 0, spatialCost: 0.2),
        ])
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "cont",
                originalIsKnownWord: false,
                isProtected: false,
                ranked: ranked
            ),
            .suggest
        )
    }

    /// Two edits that do not match where the finger landed are a spelling
    /// guess, not a slip, so they stay in the suggestion bar.
    func testTwoEditsWithWeakSpatialEvidenceOnlySuggest() {
        let ranked = KeyboardCorrectionRanking.rank([
            candidate(
                "wednesday",
                distance: 2,
                frequency: 9_000_000,
                systemRank: 0,
                spatialCost: KeyboardCorrectionRanking.unreachableSpatialCost
            ),
        ])
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "wendsaday",
                originalIsKnownWord: false,
                isProtected: false,
                ranked: ranked
            ),
            .suggest
        )
    }

    func testThreeEditCorrectionsNeverAutoReplace() {
        let ranked = KeyboardCorrectionRanking.rank([
            candidate("restaurant", distance: 3, systemRank: 0, spatialCost: 0.1),
        ])
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "restrant",
                originalIsKnownWord: false,
                isProtected: false,
                ranked: ranked
            ),
            .suggest
        )
    }

    // MARK: - Ranking

    func testCloserTapsOutrankFartherOnesWhenAllElseIsEqual() {
        let ranked = KeyboardCorrectionRanking.rank([
            candidate("fat", spatialCost: 1.4),
            candidate("far", spatialCost: 0.2),
        ])
        XCTAssertEqual(ranked.first?.word, "far")
    }

    func testBigramContextOutweighsRawFrequency() {
        let ranked = KeyboardCorrectionRanking.rank([
            candidate("tea", frequency: 50_000_000, bigramFrequency: 0),
            candidate("the", frequency: 900_000, bigramFrequency: 177_045_273_024),
        ])
        XCTAssertEqual(ranked.first?.word, "the")
    }

    func testRepeatedlyAcceptedCorrectionsRiseToTheTop() {
        let ranked = KeyboardCorrectionRanking.rank([
            candidate("ill", acceptedCount: 0),
            candidate("i'll", acceptedCount: 10),
        ])
        XCTAssertEqual(ranked.first?.word, "i'll")
    }

    func testRankingIsStableForIdenticalCandidates() {
        let ranked = KeyboardCorrectionRanking.rank([
            candidate("beta"),
            candidate("alpha"),
        ])
        XCTAssertEqual(ranked.map(\.word), ["alpha", "beta"])
    }

    // MARK: - Spatial cost

    func testTapLandingOnTheCandidateKeyIsCheap() {
        let evidence = [
            KeyboardTapEvidence(character: "s", normalizedDistances: ["s": 0.1, "d": 0.9]),
        ]
        XCTAssertEqual(
            KeyboardCorrectionRanking.spatialCost(
                original: "s",
                candidate: "d",
                evidence: evidence
            ),
            0.9,
            accuracy: 0.0001
        )
    }

    func testUnrelatedSubstitutionsAreExpensive() {
        let evidence = [
            KeyboardTapEvidence(character: "s", normalizedDistances: ["s": 0.1, "d": 0.9]),
        ]
        XCTAssertEqual(
            KeyboardCorrectionRanking.spatialCost(
                original: "s",
                candidate: "p",
                evidence: evidence
            ),
            KeyboardCorrectionRanking.unreachableSpatialCost
        )
    }

    func testIdenticalWordsCostNothing() {
        XCTAssertEqual(
            KeyboardCorrectionRanking.spatialCost(
                original: "word",
                candidate: "word",
                evidence: []
            ),
            0
        )
    }

    /// Insertions and deletions are timing errors, not aiming errors, so they
    /// get a neutral cost and are judged on frequency alone.
    func testLengthChangesFallBackToNeutralCost() {
        XCTAssertEqual(
            KeyboardCorrectionRanking.spatialCost(
                original: "wrd",
                candidate: "word",
                evidence: []
            ),
            KeyboardCorrectionRanking.neutralSpatialCost
        )
    }

    /// Text with no taps behind it — dictation, swipe, paste — must not be
    /// penalised as though the user aimed badly.
    func testMissingEvidenceIsNeutralRatherThanUnreachable() {
        XCTAssertEqual(
            KeyboardCorrectionRanking.spatialCost(
                original: "teh",
                candidate: "the",
                evidence: []
            ),
            KeyboardCorrectionRanking.neutralSpatialCost
        )
    }

    /// If the recorded taps no longer describe the text, the evidence is
    /// ignored instead of scoring the wrong positions.
    func testMisalignedEvidenceIsIgnored() {
        let evidence = [
            KeyboardTapEvidence(character: "x", normalizedDistances: ["z": 0.1]),
        ]
        XCTAssertEqual(
            KeyboardCorrectionRanking.spatialCost(
                original: "s",
                candidate: "z",
                evidence: evidence
            ),
            KeyboardCorrectionRanking.neutralSpatialCost
        )
    }

    func testMultipleDifferencesAverageTheirCost() {
        let evidence = [
            KeyboardTapEvidence(character: "a", normalizedDistances: ["s": 0.4]),
            KeyboardTapEvidence(character: "b", normalizedDistances: ["b": 0.0]),
            KeyboardTapEvidence(character: "c", normalizedDistances: ["v": 1.0]),
        ]
        XCTAssertEqual(
            KeyboardCorrectionRanking.spatialCost(
                original: "abc",
                candidate: "sbv",
                evidence: evidence
            ),
            0.7,
            accuracy: 0.0001
        )
    }
}
