import XCTest
@testable import ScribeSharedCore

final class KeyboardInteractionRulesTests: XCTestCase {
    func testAllUSKeyboardAlternates() {
        let expected: [Character: Character] = [
            "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
            "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
            "q": "1", "w": "2", "e": "3", "r": "4", "t": "5",
            "y": "6", "u": "7", "i": "8", "o": "9", "p": "0",
            "a": "@", "s": "#", "d": "$", "f": "&", "g": "*",
            "h": "(", "j": ")", "k": "'", "l": "\"",
            "z": "%", "x": "-", "c": "+", "v": "=", "b": "/",
            "n": ";", "m": ":",
        ]

        for (primary, alternate) in expected {
            XCTAssertEqual(KeyboardAlternateSymbols.alternate(for: primary), alternate)
            if primary.isLetter {
                XCTAssertEqual(
                    KeyboardAlternateSymbols.alternate(for: Character(String(primary).uppercased())),
                    alternate
                )
            }
        }
    }

    func testFlickThresholdsAreDeterministic() {
        XCTAssertEqual(resolve(x: 0, y: 11), .primary)
        XCTAssertEqual(resolve(x: 0, y: 12), .alternatePreview)
        XCTAssertEqual(resolve(x: 0, y: 17), .alternatePreview)
        XCTAssertEqual(resolve(x: 0, y: 18), .alternateCommit)
        XCTAssertEqual(resolve(x: 18, y: 2, enteredDifferentLetter: true), .primary)
		XCTAssertEqual(resolve(x: 25, y: 2, enteredDifferentLetter: true), .wordSwipe)
		XCTAssertEqual(resolve(x: 0, y: 56), .alternateCommit)
		XCTAssertEqual(resolve(x: 0, y: 56, enteredDifferentLetter: true), .alternateCommit)
		XCTAssertEqual(resolve(x: 22, y: 56, enteredDifferentLetter: true), .wordSwipe)
        XCTAssertEqual(resolve(x: 0, y: -24), .primary)
    }

    func testPortraitGeometryMatchesCapturedSystemGrid() {
        let geometry = KeyboardGeometryRules.portrait
        XCTAssertEqual(geometry.tenColumnKeyWidth(totalWidth: 440), 37.2, accuracy: 0.001)
        XCTAssertEqual(geometry.homeRowInset(totalWidth: 440), 21.6, accuracy: 0.001)
        XCTAssertEqual(geometry.controlToLetterGap(totalWidth: 440), 14.8, accuracy: 0.001)
        XCTAssertEqual(geometry.numberRowPitch, 56)
        XCTAssertEqual(geometry.toolbarToKeyGap, 6)
        XCTAssertEqual(geometry.contentHeight, 314)
        XCTAssertEqual(geometry.extensionHeight, 319)
    }

	func testCompactGeometryMatchesCapturedLandscapeSystemGrid() {
		let geometry = KeyboardGeometryRules.compact
		XCTAssertEqual(geometry.tenColumnKeyWidth(totalWidth: 724), 66.2, accuracy: 0.001)
		XCTAssertEqual(geometry.homeRowInset(totalWidth: 724), 36.1, accuracy: 0.001)
		XCTAssertEqual(geometry.controlToLetterGap(totalWidth: 724), 21.3, accuracy: 0.001)
		XCTAssertEqual(geometry.numberRowPitch, 36)
		XCTAssertEqual(geometry.toolbarToKeyGap, 5)
		XCTAssertEqual(geometry.contentHeight, 208)
		XCTAssertEqual(geometry.extensionHeight, 211)
	}

    func testCursorTranslationUsesStableCharacterSteps() {
        XCTAssertEqual(KeyboardCursorRules.characterOffset(forHorizontalTranslation: 11), 0)
        XCTAssertEqual(KeyboardCursorRules.characterOffset(forHorizontalTranslation: 12), 1)
        XCTAssertEqual(KeyboardCursorRules.characterOffset(forHorizontalTranslation: 29), 2)
        XCTAssertEqual(KeyboardCursorRules.characterOffset(forHorizontalTranslation: -25), -2)
    }

	func testControlRowsFitAllSymbolCounts() {
		let portrait = KeyboardGeometryRules.portrait
		XCTAssertEqual(
			portrait.fittedControlRowKeyWidth(totalWidth: 440, characterCount: 9),
			29.555,
			accuracy: 0.001
		)
		XCTAssertEqual(
			portrait.fittedControlRowKeyWidth(totalWidth: 440, characterCount: 6),
			47.333,
			accuracy: 0.001
		)

		let compact = KeyboardGeometryRules.compact
		XCTAssertEqual(
			compact.fittedControlRowKeyWidth(totalWidth: 724, characterCount: 9),
			53.555,
			accuracy: 0.001
		)
	}

    private func resolve(
        x: Double,
        y: Double,
        enteredDifferentLetter: Bool = false
    ) -> KeyboardGestureResolution {
        KeyboardGestureResolver.resolve(
            deltaX: x,
            deltaY: y,
            keyWidth: 37.2,
            keyHeight: 45,
            enteredDifferentLetter: enteredDifferentLetter
        )
    }
}
