import UIKit

/// A local autocorrection layer for the keyboard extension. UIKit supplies the
/// language-specific spelling candidates; Scribe filters and ranks them using
/// its frequency-ordered offline lexicon and protects the user's supplementary
/// lexicon (names, shortcuts, and learned terms).
@MainActor
final class KeyboardAutocorrectionEngine {
    private let checker = UITextChecker()
    private let frequencyRanks: [String: Int]
    private var protectedWords = Set<String>()

    convenience init() {
        self.init(words: SwipeWordDecoder.loadBundledWords())
    }

    init(words: [String]) {
        frequencyRanks = Dictionary(
            words.enumerated().map { ($0.element.lowercased(), $0.offset + 1) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func updateSupplementaryLexicon(_ lexicon: UILexicon) {
        protectedWords = Set(
            lexicon.entries.flatMap { entry in
                [entry.userInput.lowercased(), entry.documentText.lowercased()]
            }
        )
    }

    func corrections(for word: String, language: String) -> [String] {
        guard !protectedWords.contains(word.lowercased()) else { return [] }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let misspelledRange = checker.rangeOfMisspelledWord(
            in: word,
            range: range,
            startingAt: 0,
            wrap: false,
            language: language
        )
        guard misspelledRange.location != NSNotFound,
              misspelledRange.length == range.length else {
            return []
        }

        let guesses = checker.guesses(
            forWordRange: range,
            in: word,
            language: language
        ) ?? []
        return Array(
            KeyboardEditingRules.rankedCorrectionSuggestions(
                for: word,
                suggestions: guesses,
                frequencyRanks: frequencyRanks
            ).prefix(3)
        )
    }
}
