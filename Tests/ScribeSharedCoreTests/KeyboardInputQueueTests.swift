import XCTest
@testable import ScribeSharedCore

@MainActor
final class KeyboardInputQueueTests: XCTestCase {
    private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil }
    }

    func testImmediateSpaceWaitsForFinalCorrectionBeforeNextWordAndDelete() async {
        let queue = KeyboardInputQueue()
        let lookup = Gate()
        var text = "teh"
        queue.enqueue {
            await lookup.wait()
            guard !Task.isCancelled else { return }
            text = "the "
        }
        queue.enqueue { text += "c" }
        queue.enqueue { text += "a" }
        queue.enqueue { text.removeLast() }
        while lookup.continuation == nil { await Task.yield() }
        XCTAssertEqual(text, "teh")
        lookup.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(text, "the c")
    }

    func testFieldSwitchCancelsOldLookupAndBufferedKeys() async {
        let queue = KeyboardInputQueue()
        let lookup = Gate()
        var text = ""
        queue.enqueue {
            await lookup.wait()
            guard !Task.isCancelled else { return }
            text += "old correction "
        }
        queue.enqueue { text += "old queued key" }
        while lookup.continuation == nil { await Task.yield() }
        queue.cancel()
        queue.enqueue { text += "new field" }
        lookup.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(text, "new field")
    }

    func testBackToBackWordBoundariesPreserveOrder() async {
        let queue = KeyboardInputQueue()
        var text = ""
        for character in "teh cat" {
            queue.enqueue {
                if character == " " {
                    await Task.yield()
                    text = "the "
                } else {
                    text.append(character)
                }
            }
        }
        queue.enqueue { await Task.yield(); text += "\n" }
        await queue.waitUntilIdle()
        XCTAssertEqual(text, "the cat\n")
    }

    func testCrossSurfaceOverlapCommitsFinalLetterBeforeSpace() {
        let sequence = KeyboardTouchSequence()
        let letter = UUID(), space = UUID()
        var text = "ca"
        sequence.begin(id: letter) { text += "t" }
        sequence.begin(id: space) { text += " " }
        XCTAssertEqual(text, "cat")
        // The older finger lifting must not clear the active Space gesture.
        sequence.end(id: letter)
        sequence.finishActiveTouch()
        XCTAssertEqual(text, "cat ")
        sequence.finishActiveTouch()
        XCTAssertEqual(text, "cat ")
    }

    func testSpacePunctuationAndNextLetterUseSameSequence() {
        let sequence = KeyboardTouchSequence()
        var text = "hello"
        sequence.begin(id: UUID()) { text += "." }
        sequence.begin(id: UUID()) { text += " " }
        sequence.begin(id: UUID()) { text += "W" }
        sequence.finishActiveTouch()
        XCTAssertEqual(text, "hello. W")
    }

    func testCancelledTouchDoesNotCommitWhenAnotherFingerLands() {
        let sequence = KeyboardTouchSequence()
        let cancelled = UUID()
        var text = ""
        sequence.begin(id: cancelled) { text += "cancelled" }
        sequence.end(id: cancelled)
        sequence.begin(id: UUID()) { text += "a" }
        sequence.finishActiveTouch()
        XCTAssertEqual(text, "a")
    }
}
