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
}
