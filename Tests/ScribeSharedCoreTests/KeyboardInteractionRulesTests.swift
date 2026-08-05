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

    func testAlternateFlickOnlyActivatesAfterTheHoldIsArmed() {
        XCTAssertEqual(resolve(x: 0, y: 11, alternateGestureArmed: true), .primary)
        XCTAssertEqual(resolve(x: 0, y: 12, alternateGestureArmed: true), .alternatePreview)
        XCTAssertEqual(resolve(x: 0, y: 17, alternateGestureArmed: true), .alternatePreview)
        XCTAssertEqual(resolve(x: 0, y: 18, alternateGestureArmed: true), .alternateCommit)
        XCTAssertEqual(resolve(x: 0, y: 56), .primary)
        XCTAssertEqual(resolve(x: 18, y: 2, enteredDifferentLetter: true), .primary)
		XCTAssertEqual(resolve(x: 25, y: 2, enteredDifferentLetter: true), .wordSwipe)
		XCTAssertEqual(
			resolve(x: 0, y: 56, enteredDifferentLetter: true, alternateGestureArmed: true),
			.alternateCommit
		)
		XCTAssertEqual(resolve(x: 22, y: 56, enteredDifferentLetter: true), .wordSwipe)
        XCTAssertEqual(resolve(x: 0, y: -24), .primary)
    }

    func testAlternateHoldRequiresADeliberatePause() {
        XCTAssertEqual(
            KeyboardGestureResolver.alternateHoldDelay,
            .milliseconds(650)
        )
    }

    func testPortraitGeometryMatchesCapturedSystemGrid() {
        let geometry = KeyboardGeometryRules.portrait
        XCTAssertEqual(geometry.tenColumnKeyWidth(totalWidth: 440), 37.2, accuracy: 0.001)
        XCTAssertEqual(geometry.homeRowInset(totalWidth: 440), 21.6, accuracy: 0.001)
        XCTAssertEqual(geometry.controlToLetterGap(totalWidth: 440), 14.8, accuracy: 0.001)
        XCTAssertEqual(geometry.toolbarToKeyGap, 6)
        XCTAssertEqual(geometry.contentHeight, 258)
        XCTAssertEqual(geometry.extensionHeight, 263)
    }

	func testCompactGeometryMatchesCapturedLandscapeSystemGrid() {
		let geometry = KeyboardGeometryRules.compact
		XCTAssertEqual(geometry.tenColumnKeyWidth(totalWidth: 724), 66.2, accuracy: 0.001)
		XCTAssertEqual(geometry.homeRowInset(totalWidth: 724), 36.1, accuracy: 0.001)
		XCTAssertEqual(geometry.controlToLetterGap(totalWidth: 724), 21.3, accuracy: 0.001)
		XCTAssertEqual(geometry.toolbarToKeyGap, 5)
		XCTAssertEqual(geometry.contentHeight, 172)
		XCTAssertEqual(geometry.extensionHeight, 175)
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

    /// The bottom letter row used to need 324 pt of a 306 pt space on a 320 pt
    /// iPhone, because Shift and Delete were a hard 50 pt at every width.
    func testBottomLetterRowFitsAtEveryCommonWidth() {
        let portraitWidths = [320.0, 375, 390, 393, 402, 430, 440]
        for width in portraitWidths {
            let available = width - 2 * KeyboardGeometryRules.portrait.outerInset
            XCTAssertLessThanOrEqual(
                KeyboardGeometryRules.portrait.letterControlRowWidth(totalWidth: width),
                available + 0.001,
                "portrait row overflows at \(width) pt"
            )
        }

        let landscapeWidths = [568.0, 667, 736, 844, 852, 932, 956]
        for width in landscapeWidths {
            let available = width - 2 * KeyboardGeometryRules.compact.outerInset
            XCTAssertLessThanOrEqual(
                KeyboardGeometryRules.compact.letterControlRowWidth(totalWidth: width),
                available + 0.001,
                "landscape row overflows at \(width) pt"
            )
        }
    }

    /// Roomy screens keep the design-reviewed proportions exactly.
    func testWideScreensKeepThePreferredControlWidth() {
        XCTAssertEqual(
            KeyboardGeometryRules.portrait.controlWidth(totalWidth: 440),
            KeyboardGeometryRules.portrait.preferredControlWidth
        )
        XCTAssertEqual(
            KeyboardGeometryRules.compact.controlWidth(totalWidth: 956),
            KeyboardGeometryRules.compact.preferredControlWidth
        )
    }

    func testNarrowScreensShrinkTheControlKeys() {
        let narrow = KeyboardGeometryRules.portrait.controlWidth(totalWidth: 320)
        XCTAssertLessThan(narrow, KeyboardGeometryRules.portrait.preferredControlWidth)
        XCTAssertGreaterThanOrEqual(
            narrow,
            KeyboardGeometryRules.minimumControlWidth
        )
    }

    private func resolve(
        x: Double,
        y: Double,
        enteredDifferentLetter: Bool = false,
        alternateGestureArmed: Bool = false
    ) -> KeyboardGestureResolution {
        KeyboardGestureResolver.resolve(
            deltaX: x,
            deltaY: y,
            keyWidth: 37.2,
            keyHeight: 45,
            enteredDifferentLetter: enteredDifferentLetter,
            alternateGestureArmed: alternateGestureArmed
        )
    }
}
