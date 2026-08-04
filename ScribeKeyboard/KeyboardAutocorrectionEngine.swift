import UIKit

struct KeyboardCorrection: Equatable, Hashable {
    let text: String
    let automaticallyReplaces: Bool
}

/// A private, on-device correction engine for the keyboard extension. UIKit's
/// spell checker remains one signal, but candidates also come from a larger
/// frequency lexicon and are ranked with edit distance, QWERTY proximity,
/// surrounding-word frequency, and the user's accepted/rejected corrections.
@MainActor
final class KeyboardAutocorrectionEngine {
    private struct LexiconEntry {
        let word: String
        let frequency: Int64
    }

    private struct BucketKey: Hashable {
        let length: Int
        let firstLetter: Character
    }

    private struct RankedCandidate {
        let word: String
        let distance: Int
        let frequency: Int64
        let bigramFrequency: Int64
        let systemRank: Int?
        let score: Double
    }

    private let checker = UITextChecker()
    private let frequencies: [String: Int64]
    private let entriesByBucket: [BucketKey: [LexiconEntry]]
    private let bigramFrequencies: [String: [String: Int64]]
    private var protectedWords = Set<String>()
    private var acceptedCorrections: [String: Int]
    private let defaults: UserDefaults

    private static let rejectedWordsKey = "keyboard.autocorrect.rejectedWords.v1"
    private static let acceptedCorrectionsKey = "keyboard.autocorrect.acceptedPairs.v1"

    convenience init() {
        self.init(
            words: Self.loadFrequencyWords(),
            bigrams: Self.loadBigrams(),
            defaults: .standard
        )
    }

    init(
        words: [(word: String, frequency: Int64)],
        bigrams: [(first: String, second: String, frequency: Int64)],
        defaults: UserDefaults
    ) {
        self.defaults = defaults
        frequencies = Dictionary(
            words.map { ($0.word, $0.frequency) },
            uniquingKeysWith: max
        )

        var buckets: [BucketKey: [LexiconEntry]] = [:]
        for entry in words {
            guard let firstLetter = entry.word.first else { continue }
            buckets[
                BucketKey(length: entry.word.count, firstLetter: firstLetter),
                default: []
            ].append(LexiconEntry(word: entry.word, frequency: entry.frequency))
        }
        entriesByBucket = buckets

        var bigramBuckets: [String: [String: Int64]] = [:]
        for bigram in bigrams {
            bigramBuckets[bigram.first, default: [:]][bigram.second] = bigram.frequency
        }
        bigramFrequencies = bigramBuckets

        protectedWords = Set(defaults.stringArray(forKey: Self.rejectedWordsKey) ?? [])
        acceptedCorrections = defaults.dictionary(forKey: Self.acceptedCorrectionsKey) as? [String: Int] ?? [:]
    }

    func updateSupplementaryLexicon(_ lexicon: UILexicon) {
        protectedWords.formUnion(
            lexicon.entries.flatMap { entry in
                [entry.userInput.lowercased(), entry.documentText.lowercased()]
            }
        )
    }

    func corrections(
        for word: String,
        contextBefore: String?,
        language: String
    ) -> [KeyboardCorrection] {
        let original = word.lowercased()
        guard original.count >= 2,
              !protectedWords.contains(original),
              language.lowercased().hasPrefix("en") else {
            return []
        }

        let previousWord = KeyboardEditingRules.wordBeforeAutocorrectionWord(
            contextBefore: contextBefore
        )?.lowercased()
        let spellingResult = spellingResult(for: word, language: language)
        let systemSuggestions = spellingResult.suggestions
        let systemRanks = Dictionary(
            systemSuggestions.enumerated().map {
                ($0.element.lowercased(), $0.offset)
            },
            uniquingKeysWith: min
        )
        let isMisspelled = spellingResult.isMisspelled

        var candidateWords = Set(systemRanks.keys)
        candidateWords.formUnion(lexiconCandidates(for: original))
        candidateWords.remove(original)

        let ranked = candidateWords.compactMap { candidate -> RankedCandidate? in
            let distance = KeyboardEditingRules.correctionDistance(original, candidate)
            let maximumDistance = original.count >= 8 ? 3 : (original.count >= 4 ? 2 : 1)
            guard distance <= maximumDistance else { return nil }

            let frequency = frequencies[candidate] ?? 1
            let bigramFrequency = previousWord.flatMap {
                bigramFrequencies[$0]?[candidate]
            } ?? 0
            let acceptedCount = acceptedCorrections[Self.pairKey(original, candidate)] ?? 0
            let systemRank = systemRanks[candidate]
            var score = Double(distance) * 100
            score += Double(systemRank ?? 8) * 3
            score -= log10(Double(frequency) + 1) * 3.5
            score -= log10(Double(bigramFrequency) + 1) * 7
            score -= Double(min(acceptedCount, 12)) * 4
            if isSingleNeighborSubstitution(original, candidate) { score -= 12 }
            if systemRank != nil { score -= 20 }

            return RankedCandidate(
                word: candidate,
                distance: distance,
                frequency: frequency,
                bigramFrequency: bigramFrequency,
                systemRank: systemRank,
                score: score
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.frequency != rhs.frequency { return lhs.frequency > rhs.frequency }
            return lhs.word < rhs.word
        }

        guard let best = ranked.first else { return [] }
        let originalBigramFrequency = previousWord.flatMap {
            bigramFrequencies[$0]?[original]
        } ?? 0
        let runnerUpScore = ranked.dropFirst().first?.score ?? .infinity
        let automaticallyReplaces = shouldAutomaticallyReplace(
            original: original,
            candidate: best,
            isMisspelled: isMisspelled,
            originalBigramFrequency: originalBigramFrequency,
            scoreMargin: runnerUpScore - best.score
        )

        return Array(ranked.prefix(3).map { candidate in
            KeyboardCorrection(
                text: candidate.word,
                automaticallyReplaces: candidate.word == best.word && automaticallyReplaces
            )
        })
    }

    func recordAccepted(original: String, replacement: String) {
        let key = Self.pairKey(original.lowercased(), replacement.lowercased())
        let nextCount = min(100, (acceptedCorrections[key] ?? 0) + 1)
        acceptedCorrections[key] = nextCount
        defaults.set(acceptedCorrections, forKey: Self.acceptedCorrectionsKey)
    }

    func recordRejected(original: String, replacement: String) {
        let normalized = original.lowercased()
        protectedWords.insert(normalized)
        defaults.set(Array(protectedWords.prefix(512)), forKey: Self.rejectedWordsKey)

        let key = Self.pairKey(normalized, replacement.lowercased())
        acceptedCorrections.removeValue(forKey: key)
        defaults.set(acceptedCorrections, forKey: Self.acceptedCorrectionsKey)
    }

    private func spellingResult(
        for word: String,
        language: String
    ) -> (isMisspelled: Bool, suggestions: [String]) {
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
            return (false, [])
        }
        return (
            true,
            checker.guesses(
                forWordRange: range,
                in: word,
                language: language
            ) ?? []
        )
    }

    private func lexiconCandidates(for original: String) -> Set<String> {
        guard let firstLetter = original.first else { return [] }
        let maximumDistance = original.count >= 8 ? 3 : (original.count >= 4 ? 2 : 1)
        var possibleFirstLetters: Set<Character> = [firstLetter]
        for character in "abcdefghijklmnopqrstuvwxyz"
        where SwipeWordDecoder.areNeighbors(firstLetter, character) {
            possibleFirstLetters.insert(character)
        }

        var results = Set<String>()
        for length in max(1, original.count - maximumDistance)...(original.count + maximumDistance) {
            for first in possibleFirstLetters {
                let entries = entriesByBucket[BucketKey(length: length, firstLetter: first)] ?? []
                for entry in entries where KeyboardEditingRules.correctionDistance(
                    original,
                    entry.word
                ) <= maximumDistance {
                    results.insert(entry.word)
                }
            }
        }
        return results
    }

    private func shouldAutomaticallyReplace(
        original: String,
        candidate: RankedCandidate,
        isMisspelled: Bool,
        originalBigramFrequency: Int64,
        scoreMargin: Double
    ) -> Bool {
        if isMisspelled {
            if candidate.distance == 1 { return true }
            return original.count >= 5
                && candidate.distance == 2
                && (candidate.systemRank == 0 || scoreMargin >= 10)
        }

        guard candidate.distance == 1,
              candidate.bigramFrequency >= 10_000_000 else {
            return false
        }
        return originalBigramFrequency == 0
            || candidate.bigramFrequency / max(1, originalBigramFrequency) >= 50
    }

    private func isSingleNeighborSubstitution(_ source: String, _ destination: String) -> Bool {
        guard source.count == destination.count else { return false }
        let pairs = zip(source, destination).filter { pair in pair.0 != pair.1 }
        guard pairs.count == 1, let pair = pairs.first else { return false }
        return SwipeWordDecoder.areNeighbors(pair.0, pair.1)
    }

    private static func pairKey(_ original: String, _ replacement: String) -> String {
        "\(original)\n\(replacement)"
    }

    private static func loadFrequencyWords() -> [(word: String, frequency: Int64)] {
        guard let url = Bundle.main.url(forResource: "AutocorrectWords", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return contents.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 2, let frequency = Int64(fields[1]) else { return nil }
            return (String(fields[0]), frequency)
        }
    }

    private static func loadBigrams() -> [(first: String, second: String, frequency: Int64)] {
        guard let url = Bundle.main.url(forResource: "AutocorrectBigrams", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return contents.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 3, let frequency = Int64(fields[2]) else { return nil }
            return (String(fields[0]), String(fields[1]), frequency)
        }
    }
}
