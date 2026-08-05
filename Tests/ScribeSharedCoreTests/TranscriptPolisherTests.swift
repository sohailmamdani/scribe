import XCTest
@testable import ScribeSharedCore

final class TranscriptPolisherTests: XCTestCase {
    func testRemovesWhisperBlankAudioMarkers() {
        XCTAssertEqual(
            TranscriptPolisher.polish("This is useful. [BLANK_AUDIO]"),
            "This is useful."
        )
        XCTAssertEqual(TranscriptPolisher.polish("[blank_audio]"), "")
        XCTAssertEqual(
            TranscriptPolisher.polish("Finished. [NO SPEECH]"),
            "Finished."
        )
    }

    func testPreservesOrdinaryBracketedAndSpokenText() {
        XCTAssertEqual(
            TranscriptPolisher.polish("keep [this note] please"),
            "Keep [this note] please"
        )
        XCTAssertEqual(
            TranscriptPolisher.polish("the phrase blank audio matters"),
            "The phrase blank audio matters"
        )
    }

    // MARK: - Language-model refinement guard
    //
    // The on-device model is only allowed to punctuate, recase, and drop
    // fillers. Everything below is a way it could exceed that, and every one
    // must be rejected in favour of the deterministic transcript.

    func testPunctuationAndCasingChangesAreAccepted() {
        XCTAssertTrue(
            TranscriptPolisher.isFaithfulRefinement(
                "Let's meet at three. I'll bring the notes.",
                of: "lets meet at three ill bring the notes"
            ) == false,
            "apostrophes change the words themselves, so this is not a safe rewrite"
        )
        XCTAssertTrue(
            TranscriptPolisher.isFaithfulRefinement(
                "Ship it on Friday. Then tell the team.",
                of: "ship it on friday then tell the team"
            )
        )
    }

    func testDroppingFillersAndStuttersIsAccepted() {
        XCTAssertTrue(
            TranscriptPolisher.isFaithfulRefinement(
                "I think we should ship it.",
                of: "um i think uh we we should ship it"
            )
        )
    }

    /// The failure that matters: the model answering the transcript instead of
    /// cleaning it.
    func testInventedContentIsRejected() {
        XCTAssertFalse(
            TranscriptPolisher.isFaithfulRefinement(
                "Sure! Here is your cleaned transcript: Ship it on Friday.",
                of: "ship it on friday"
            )
        )
        XCTAssertFalse(
            TranscriptPolisher.isFaithfulRefinement(
                "The deploy is scheduled for Friday afternoon.",
                of: "ship it on friday"
            )
        )
    }

    func testSubstitutedWordsAreRejected() {
        XCTAssertFalse(
            TranscriptPolisher.isFaithfulRefinement(
                "Ship it on Thursday.",
                of: "ship it on friday"
            )
        )
    }

    func testReorderedWordsAreRejected() {
        XCTAssertFalse(
            TranscriptPolisher.isFaithfulRefinement(
                "On Friday, ship it.",
                of: "ship it on friday"
            )
        )
    }

    /// Expanding contractions is harmless in itself but indistinguishable from
    /// rewriting, so it is refused deliberately.
    func testExpandingWordsIsRejected() {
        XCTAssertFalse(
            TranscriptPolisher.isFaithfulRefinement(
                "I am going to ship it.",
                of: "im gonna ship it"
            )
        )
    }

    func testEmptyOrLongerOutputIsRejected() {
        XCTAssertFalse(TranscriptPolisher.isFaithfulRefinement("", of: "ship it on friday"))
        XCTAssertFalse(
            TranscriptPolisher.isFaithfulRefinement(
                "ship it on friday ship it on friday",
                of: "ship it on friday"
            )
        )
    }

    func testUnchangedTextIsFaithful() {
        XCTAssertTrue(
            TranscriptPolisher.isFaithfulRefinement(
                "Ship it on Friday.",
                of: "Ship it on Friday."
            )
        )
    }

    func testComparableWordsIgnorePunctuationAndCase() {
        XCTAssertEqual(
            TranscriptPolisher.comparableWords("Ship it, on Friday!"),
            ["ship", "it", "on", "friday"]
        )
        XCTAssertEqual(
            TranscriptPolisher.comparableWords("don’t"),
            ["don't"]
        )
    }
}
