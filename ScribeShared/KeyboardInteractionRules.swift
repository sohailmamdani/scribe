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

/// The two symbol pages mirror Gboard's familiar English layout. Keeping the
/// rows in the shared target makes the visual contract testable without
/// launching a keyboard extension.
enum KeyboardSymbolLayouts {
    static let numbers: [[Character]] = [
        Array("1234567890"),
        Array("-/:;()$&@\""),
        Array(".,?!'"),
    ]

    static let symbols: [[Character]] = [
        Array("[]{}#%^*+="),
        Array("_\\|~<>€£¥"),
        Array(".,?!'"),
    ]
}

/// Gboard's period key expands into two rows of punctuation. The popup is
/// right-aligned with the period key, so hit resolution accepts coordinates in
/// that key's local space even when the finger has travelled far to the left.
enum KeyboardPunctuationPalette {
    static let rows: [[Character]] = [
        Array("&%+\"-:'@"),
        Array(";/()#!,?"),
    ]

    static var columnCount: Int { rows.map(\.count).max() ?? 0 }

    static func symbol(
        atX x: Double,
        y: Double,
        anchorKeyWidth: Double,
        popupWidth: Double,
        popupHeight: Double,
        gap: Double
    ) -> Character? {
        guard columnCount > 0,
              popupWidth > 0,
              popupHeight > 0 else { return nil }

        let minX = anchorKeyWidth - popupWidth
        let minY = -(popupHeight + gap)
        let maxY = -gap
        guard x >= minX,
              x <= anchorKeyWidth,
              y >= minY,
              y <= maxY else { return nil }

        let cellWidth = popupWidth / Double(columnCount)
        let cellHeight = popupHeight / Double(rows.count)
        let column = min(columnCount - 1, max(0, Int((x - minX) / cellWidth)))
        let row = min(rows.count - 1, max(0, Int((y - minY) / cellHeight)))
        guard column < rows[row].count else { return nil }
        return rows[row][column]
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
    /// A symbol should require an unmistakable hold. Four hundred milliseconds
    /// was close enough to an ordinary deliberate key press that alternates
    /// could appear accidentally.
    static let alternateHoldDelay: Duration = .milliseconds(650)

    static func resolve(
        deltaX: Double,
        deltaY: Double,
        keyWidth: Double,
        keyHeight: Double,
        enteredDifferentLetter: Bool,
        alternateGestureArmed: Bool
    ) -> KeyboardGestureResolution {
        let distance = hypot(deltaX, deltaY)
        let horizontalCorridor = min(14, keyWidth * 0.38)
        let isVerticalDownwardGesture = deltaY >= previewDistance
            && abs(deltaX) <= horizontalCorridor
            && deltaY >= 1.5 * abs(deltaX)

        // Ordinary taps often drift downward while the finger lifts. That
        // movement can only become an alternate after the deliberate hold has
        // armed symbol selection.
        if alternateGestureArmed, isVerticalDownwardGesture {
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
    /// Target width for Shift and Delete on a roomy screen. The width actually
    /// used is `controlWidth(totalWidth:)`, which shrinks this when the screen
    /// cannot afford it.
    let preferredControlWidth: Double
    let hostHeightAdjustment: Double

    static let portrait = KeyboardGeometryRules(
        keyHeight: 45,
        horizontalGap: 6,
        verticalGap: 11,
        outerInset: 7,
        toolbarHeight: 39,
        toolbarToKeyGap: 6,
        preferredControlWidth: 50,
        hostHeightAdjustment: 5
    )

    static let compact = KeyboardGeometryRules(
        keyHeight: 27,
        horizontalGap: 6,
        verticalGap: 9,
        outerInset: 4,
        toolbarHeight: 32,
        toolbarToKeyGap: 5,
        preferredControlWidth: 87,
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

    /// Shift and Delete shrink rather than overflow.
    ///
    /// These used to be a hard 50 pt (87 pt compact) at every screen width. On
    /// a 320 pt iPhone the bottom letter row then needed 324 pt of a 306 pt
    /// space and overflowed by 18 pt, squeezing the row it was supposed to
    /// frame. Roomy screens are unaffected: the preferred width still wins
    /// wherever it fits.
    /// Floor for a shrunken control key. The hit grid extends Shift and Delete
    /// to the screen edge, so the touch target stays comfortably larger than
    /// the cap. This only stops the cap collapsing at absurd widths.
    static let minimumControlWidth: Double = 32

    func controlWidth(totalWidth: Double) -> Double {
        let available = totalWidth - 2 * outerInset
        let letters = 7 * tenColumnKeyWidth(totalWidth: totalWidth) + 6 * horizontalGap
        // Reserve at least one standard gap on each side of the letter block.
        let affordable = (available - letters - 2 * horizontalGap) / 2
        return max(
            Self.minimumControlWidth,
            min(preferredControlWidth, affordable)
        )
    }

    func controlToLetterGap(totalWidth: Double) -> Double {
        let available = totalWidth - 2 * outerInset
        let letters = 7 * tenColumnKeyWidth(totalWidth: totalWidth)
        let internalLetterGaps = 6 * horizontalGap
        let controls = 2 * controlWidth(totalWidth: totalWidth)
        return max(horizontalGap, (available - controls - letters - internalLetterGaps) / 2)
    }

	func fittedControlRowKeyWidth(totalWidth: Double, characterCount: Int) -> Double {
		guard characterCount > 0 else { return 0 }
		let available = totalWidth - 2 * outerInset
		let gapCount = Double(characterCount + 1)
		let controls = 2 * controlWidth(totalWidth: totalWidth)
		return max(
			1,
			(available - controls - gapCount * horizontalGap) / Double(characterCount)
		)
	}

    /// Total width the bottom letter row needs. Must never exceed the space
    /// available, or the row overflows and the layout compresses.
    func letterControlRowWidth(totalWidth: Double) -> Double {
        2 * controlWidth(totalWidth: totalWidth)
            + 2 * controlToLetterGap(totalWidth: totalWidth)
            + 7 * tenColumnKeyWidth(totalWidth: totalWidth)
            + 6 * horizontalGap
    }
}

enum KeyboardCursorRules {
    static let pointsPerCharacter = 12.0

    static func characterOffset(forHorizontalTranslation translation: Double) -> Int {
        Int(translation / pointsPerCharacter)
    }
}
