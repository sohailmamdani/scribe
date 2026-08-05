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
        acceptedCount: Int = 0,
        changesFirstLetter: Bool = false
    ) -> KeyboardCorrectionCandidate {
        KeyboardCorrectionCandidate(
            word: word,
            distance: distance,
            frequency: frequency,
            bigramFrequency: bigramFrequency,
            systemRank: systemRank,
            spatialCost: spatialCost,
            acceptedCount: acceptedCount,
            changesFirstLetter: changesFirstLetter
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

    /// A system-recognized, one-edit repair should not need the same enormous
    /// lead as a lexicon-only guess. This is the gap that left ordinary typos
    /// visible in the bar but never committed them on space.
    func testRecognizedOneEditWinnerUsesPracticalAutoReplaceMargin() {
        let ranked = KeyboardCorrectionRanking.rank([
            candidate("word", frequency: 10_000_000, systemRank: 0, spatialCost: 0.25),
            candidate("ward", frequency: 10_000_000, systemRank: 1, spatialCost: 0.55),
        ])
        let margin = KeyboardCorrectionRanking.score(ranked[1])
            - KeyboardCorrectionRanking.score(ranked[0])
        XCTAssertGreaterThanOrEqual(
            margin,
            KeyboardCorrectionRanking.recognizedOneEditAutoReplaceMargin
        )
        XCTAssertLessThan(margin, KeyboardCorrectionRanking.autoReplaceMargin)
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "wprd",
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

    // MARK: - Frequency has to be able to outvote the system spell checker

    /// Real data for "Smple", taken from the bundled lexicon and Apple's own
    /// guesses. Every candidate is one edit away, so frequency and the shape of
    /// the edit are all there is to separate them.
    private func smpleCandidates() -> [KeyboardCorrectionCandidate] {
        [
            // Apple lists these first, but they are rare or implausible.
            candidate("ample", frequency: 3_187_842, systemRank: 0,
                      spatialCost: KeyboardCorrectionRanking.neutralSpatialCost,
                      changesFirstLetter: true),
            candidate("smile", frequency: 13_893_537, systemRank: 1,
                      spatialCost: KeyboardCorrectionRanking.unreachableSpatialCost),
            candidate("sample", frequency: 68_957_421, systemRank: 2,
                      spatialCost: KeyboardCorrectionRanking.neutralSpatialCost),
            candidate("simple", frequency: 85_617_922, systemRank: 3,
                      spatialCost: KeyboardCorrectionRanking.neutralSpatialCost),
        ]
    }

    /// The reported bug: typing "Smple" offered "Smile", "Sample" and "Ample"
    /// — the intended word was not in the bar at all. The old weighting left
    /// all four within 3.3 points, so Apple's ordering decided everything.
    ///
    /// The fix demotes the two implausible readings. It deliberately does not
    /// claim to separate "simple" from "sample": at 85.6M against 69.0M those
    /// are 1.24× apart, which `log10` compresses to under 2 points, and both
    /// are a single inserted letter. They are a real tie, and the honest
    /// outcome is to offer both.
    func testImplausibleCandidatesAreDemotedBelowThePlausibleOnes() {
        let ranked = KeyboardCorrectionRanking.rank(smpleCandidates())
        let top = Set(ranked.prefix(2).map(\.word))
        XCTAssertEqual(top, ["simple", "sample"])

        // "ample" rewrites the deliberately-shifted opening letter and is 27×
        // rarer; "smile" needs a tap two keys off target. Both sit below.
        let order = ranked.map(\.word)
        for demoted in ["ample", "smile"] {
            XCTAssertGreaterThan(
                order.firstIndex(of: demoted) ?? .max,
                order.firstIndex(of: "sample") ?? 0,
                "\(demoted) should rank below the plausible readings"
            )
        }
    }

    /// Apple ranked "ample" first and "simple" last for this word. Whatever it
    /// says, the implausible candidate must not lead.
    func testSystemOrderingCannotPromoteAnImplausibleCandidate() {
        let ranked = KeyboardCorrectionRanking.rank(smpleCandidates())
        XCTAssertNotEqual(ranked.first?.word, "ample")
    }

    /// Frequency must dominate the system-rank nudge, not the other way round.
    func testFrequencyOutweighsSystemRank() {
        let spread = KeyboardCorrectionRanking.score(
            candidate("ample", frequency: 3_187_842, systemRank: 0)
        ) - KeyboardCorrectionRanking.score(
            candidate("simple", frequency: 85_617_922, systemRank: 3)
        )
        XCTAssertGreaterThan(spread, 18)
    }

    /// A word Apple does not offer at all must still be reachable on strength
    /// of frequency. The old scoring charged it 28 points — more than the whole
    /// frequency spread — so it could never win.
    func testAbsenceFromTheSystemListIsANudgeNotAVeto() {
        let penalty = KeyboardCorrectionRanking.score(candidate("word", systemRank: nil))
            - KeyboardCorrectionRanking.score(candidate("word", systemRank: 0))
        XCTAssertLessThanOrEqual(penalty, 10)
    }

    /// People rarely miss the opening key, especially right after pressing
    /// Shift for it. That is what keeps "ample" behind "simple".
    func testRewritingTheFirstLetterIsPenalised() {
        let cost = KeyboardCorrectionRanking.score(
            candidate("ample", changesFirstLetter: true)
        ) - KeyboardCorrectionRanking.score(
            candidate("ample", changesFirstLetter: false)
        )
        XCTAssertEqual(cost, KeyboardCorrectionRanking.firstLetterPenalty, accuracy: 0.001)
    }

    /// "Smple" is genuinely ambiguous between "simple" and "sample" on letters
    /// and frequency alone, so it must surface as a suggestion rather than
    /// silently rewriting itself. Context is what resolves this in real use.
    func testGenuinelyAmbiguousWordSuggestsRatherThanReplacing() {
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "smple",
                originalIsKnownWord: false,
                isProtected: false,
                ranked: KeyboardCorrectionRanking.rank(smpleCandidates())
            ),
            .suggest
        )
    }

    /// ...and the bigram that real typing supplies is enough to break the tie.
    func testContextResolvesTheAmbiguityIntoAnAutomaticCorrection() {
        var withContext = smpleCandidates()
        withContext = withContext.map { entry in
            guard entry.word == "simple" else { return entry }
            return candidate(
                "simple",
                frequency: 85_617_922,
                bigramFrequency: 12_000_000,
                systemRank: 3,
                spatialCost: KeyboardCorrectionRanking.neutralSpatialCost
            )
        }
        let ranked = KeyboardCorrectionRanking.rank(withContext)
        XCTAssertEqual(ranked.first?.word, "simple")
        XCTAssertEqual(
            KeyboardCorrectionRanking.decision(
                original: "smple",
                originalIsKnownWord: false,
                isProtected: false,
                ranked: ranked
            ),
            .autoReplace
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
