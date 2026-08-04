import Foundation

enum KeyboardAlternateSymbols {
    private static let values: [Character: Character] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
        "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "q": "1", "w": "2", "e": "3", "r": "4", "t": "5",
        "y": "6", "u": "7", "i": "8", "o": "9", "p": "0",
        "a": "@", "s": "#", "d": "$", "f": "&", "g": "*",
        "h": "(", "j": ")", "k": "'", "l": "\"",
        "z": "%", "x": "-", "c": "+", "v": "=", "b": "/",
        "n": ";", "m": ":",
    ]

    static func alternate(for character: Character) -> Character? {
        values[Character(String(character).lowercased())]
    }

    static func spokenName(for character: Character) -> String {
        switch character {
        case "!": "exclamation mark"
        case "@": "at sign"
        case "#": "number sign"
        case "$": "dollar sign"
        case "%": "percent sign"
        case "^": "caret"
        case "&": "ampersand"
        case "*": "asterisk"
        case "(": "left parenthesis"
        case ")": "right parenthesis"
        case "'": "apostrophe"
        case "\"": "quotation mark"
        case "-": "hyphen"
        case "+": "plus sign"
        case "=": "equals sign"
        case "/": "slash"
        case ";": "semicolon"
        case ":": "colon"
        default: String(character)
        }
    }
}

enum KeyboardGestureResolution: Equatable {
    case primary
    case alternatePreview
    case alternateCommit
    case wordSwipe
}

enum KeyboardGestureResolver {
    static let previewDistance = 12.0
    static let commitDistance = 18.0
    static let swipeDistance = 24.0

    static func resolve(
        deltaX: Double,
        deltaY: Double,
        keyWidth: Double,
        keyHeight: Double,
        enteredDifferentLetter: Bool
    ) -> KeyboardGestureResolution {
        let distance = hypot(deltaX, deltaY)
        let horizontalCorridor = min(14, keyWidth * 0.38)
        let isVerticalDownwardGesture = deltaY >= previewDistance
            && abs(deltaX) <= horizontalCorridor
            && deltaY >= 1.5 * abs(deltaX)

        // A straight downward flick stays an alternate even if the finger
        // overshoots the cap. Only entering another letter beyond the compact
        // flick corridor is allowed to turn it into word swiping.
        if isVerticalDownwardGesture {
            return deltaY >= commitDistance ? .alternateCommit : .alternatePreview
        }

        if enteredDifferentLetter, distance >= swipeDistance {
            return .wordSwipe
        }

        return .primary
    }
}

struct KeyboardGeometryRules: Equatable {
    let keyHeight: Double
    let horizontalGap: Double
    let verticalGap: Double
    let outerInset: Double
    let toolbarHeight: Double
    let toolbarToKeyGap: Double
    let controlWidth: Double
    let hostHeightAdjustment: Double

    static let portrait = KeyboardGeometryRules(
        keyHeight: 45,
        horizontalGap: 6,
        verticalGap: 11,
        outerInset: 7,
        toolbarHeight: 39,
        toolbarToKeyGap: 6,
        controlWidth: 50,
        hostHeightAdjustment: 5
    )

    static let compact = KeyboardGeometryRules(
        keyHeight: 27,
        horizontalGap: 6,
        verticalGap: 9,
        outerInset: 4,
        toolbarHeight: 32,
        toolbarToKeyGap: 5,
        controlWidth: 87,
        hostHeightAdjustment: 3
    )

    // Toolbar plus QWERTY, home, bottom-letter, and control rows.
    var contentHeight: Double {
        toolbarHeight + toolbarToKeyGap + 4 * keyHeight + 3 * verticalGap
    }
    var extensionHeight: Double { contentHeight + hostHeightAdjustment }

    func tenColumnKeyWidth(totalWidth: Double) -> Double {
        (totalWidth - 2 * outerInset - 9 * horizontalGap) / 10
    }

    func homeRowInset(totalWidth: Double) -> Double {
        (tenColumnKeyWidth(totalWidth: totalWidth) + horizontalGap) / 2
    }

    func controlToLetterGap(totalWidth: Double) -> Double {
        let available = totalWidth - 2 * outerInset
        let letters = 7 * tenColumnKeyWidth(totalWidth: totalWidth)
        let internalLetterGaps = 6 * horizontalGap
        return max(horizontalGap, (available - 2 * controlWidth - letters - internalLetterGaps) / 2)
    }

	func fittedControlRowKeyWidth(totalWidth: Double, characterCount: Int) -> Double {
		guard characterCount > 0 else { return 0 }
		let available = totalWidth - 2 * outerInset
		let gapCount = Double(characterCount + 1)
		return max(
			1,
			(available - 2 * controlWidth - gapCount * horizontalGap) / Double(characterCount)
		)
	}
}

enum KeyboardCursorRules {
    static let pointsPerCharacter = 12.0

    static func characterOffset(forHorizontalTranslation translation: Double) -> Int {
        Int(translation / pointsPerCharacter)
    }
}
