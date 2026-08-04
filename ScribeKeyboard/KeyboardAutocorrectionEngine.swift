import UIKit

struct KeyboardCorrection: Equatable, Hashable, Sendable {
    let text: String
    let automaticallyReplaces: Bool
}

/// A private, on-device correction engine for the keyboard extension.
///
/// This is an `actor` on purpose. It previously ran on the main actor and was
/// invoked after every keystroke, where it walked whole length buckets of a
/// 20,000-word lexicon computing full edit-distance matrices — thousands of
/// dynamic-programming runs per character, on the thread responsible for
/// receiving touches. That stall is a direct cause of dropped and mistyped
/// keys. Candidate generation now happens off the main thread, behind a cheap
/// bitmask prefilter, and the result is delivered back asynchronously.
actor KeyboardAutocorrectionEngine {
    private struct LexiconEntry {
        let word: String
        let frequency: Int64
        /// One bit per a–z letter present in the word.
        let mask: UInt32
    }

    private struct BucketKey: Hashable {
        let length: Int
        let firstLetter: Character
    }

    private let checker = UITextChecker()
    private let frequencies: [String: Int64]
    private let entriesByBucket: [BucketKey: [LexiconEntry]]
    private let bigramFrequencies: [String: [String: Int64]]
    /// Ordered most-recent-last so trimming drops the oldest rejections rather
    /// than an arbitrary slice of an unordered set.
    private var protectedWords: [String]
    private var protectedWordLookup: Set<String>
    private var acceptedCorrections: [String: Int]
    private let defaults: UserDefaults

    private static let rejectedWordsKey = "keyboard.autocorrect.rejectedWords.v2"
    private static let acceptedCorrectionsKey = "keyboard.autocorrect.acceptedPairs.v2"
    private static let maximumProtectedWords = 512

    init() {
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
            ].append(
                LexiconEntry(
                    word: entry.word,
                    frequency: entry.frequency,
                    mask: Self.letterMask(entry.word)
                )
            )
        }
        entriesByBucket = buckets

        var bigramBuckets: [String: [String: Int64]] = [:]
        for bigram in bigrams {
            bigramBuckets[bigram.first, default: [:]][bigram.second] = bigram.frequency
        }
        bigramFrequencies = bigramBuckets

        let storedProtected = defaults.stringArray(forKey: Self.rejectedWordsKey) ?? []
        protectedWords = storedProtected
        protectedWordLookup = Set(storedProtected)
        acceptedCorrections = defaults.dictionary(forKey: Self.acceptedCorrectionsKey) as? [String: Int] ?? [:]
    }

    func updateSupplementaryLexicon(entries: [String]) {
        for entry in entries {
            let normalized = entry.lowercased()
            guard !normalized.isEmpty, protectedWordLookup.insert(normalized).inserted else {
                continue
            }
            protectedWords.append(normalized)
        }
        trimProtectedWords()
    }

    func corrections(
        for word: String,
        contextBefore: String?,
        language: String,
        evidence: [KeyboardTapEvidence]
    ) -> [KeyboardCorrection] {
        let original = word.lowercased()
        guard original.count >= 2,
              language.lowercased().hasPrefix("en") else {
            return []
        }
        let isProtected = protectedWordLookup.contains(original)

        let previousWord = KeyboardEditingRules.wordBeforeAutocorrectionWord(
            contextBefore: contextBefore
        )?.lowercased()
        let spelling = spellingResult(for: word, language: language)
        let systemRanks = Dictionary(
            spelling.suggestions.enumerated().map {
                ($0.element.lowercased(), $0.offset)
            },
            uniquingKeysWith: min
        )

        var candidateWords = Set(systemRanks.keys)
        candidateWords.formUnion(lexiconCandidates(for: original))
        candidateWords.remove(original)

        let maximumDistance = Self.maximumDistance(forLength: original.count)
        let candidates = candidateWords.compactMap { candidate -> KeyboardCorrectionCandidate? in
            guard KeyboardEditingRules.isWordSafeCorrectionCandidate(candidate) else {
                return nil
            }
            let distance = KeyboardEditingRules.correctionDistance(original, candidate)
            guard distance <= maximumDistance else { return nil }

            return KeyboardCorrectionCandidate(
                word: candidate,
                distance: distance,
                frequency: frequencies[candidate] ?? 1,
                bigramFrequency: previousWord.flatMap {
                    bigramFrequencies[$0]?[candidate]
                } ?? 0,
                systemRank: systemRanks[candidate],
                spatialCost: KeyboardCorrectionRanking.spatialCost(
                    original: original,
                    candidate: candidate,
                    evidence: evidence
                ),
                acceptedCount: acceptedCorrections[Self.pairKey(original, candidate)] ?? 0
            )
        }

        let ranked = KeyboardCorrectionRanking.rank(candidates)
        let decision = KeyboardCorrectionRanking.decision(
            original: original,
            originalIsKnownWord: !spelling.isMisspelled || frequencies[original] != nil,
            isProtected: isProtected,
            ranked: ranked
        )
        guard decision != .none else { return [] }

        return ranked.prefix(3).enumerated().map { index, candidate in
            KeyboardCorrection(
                text: candidate.word,
                automaticallyReplaces: index == 0 && decision == .autoReplace
            )
        }
    }

    func recordAccepted(original: String, replacement: String) {
        let key = Self.pairKey(original.lowercased(), replacement.lowercased())
        acceptedCorrections[key] = min(100, (acceptedCorrections[key] ?? 0) + 1)
        defaults.set(acceptedCorrections, forKey: Self.acceptedCorrectionsKey)
    }

    func recordRejected(original: String, replacement: String) {
        let normalized = original.lowercased()
        if protectedWordLookup.insert(normalized).inserted {
            protectedWords.append(normalized)
        }
        trimProtectedWords()

        acceptedCorrections.removeValue(
            forKey: Self.pairKey(normalized, replacement.lowercased())
        )
        defaults.set(acceptedCorrections, forKey: Self.acceptedCorrectionsKey)
    }

    private func trimProtectedWords() {
        if protectedWords.count > Self.maximumProtectedWords {
            let dropped = protectedWords.prefix(protectedWords.count - Self.maximumProtectedWords)
            protectedWords.removeFirst(dropped.count)
            protectedWordLookup = Set(protectedWords)
        }
        defaults.set(protectedWords, forKey: Self.rejectedWordsKey)
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
            checker.guesses(forWordRange: range, in: word, language: language) ?? []
        )
    }

    /// Collects plausible lexicon words without running edit distance against
    /// every entry. The bitmask test below is two instructions and removes the
    /// overwhelming majority of a bucket before any matrix is allocated.
    private func lexiconCandidates(for original: String) -> Set<String> {
        guard let firstLetter = original.first else { return [] }
        let maximumDistance = Self.maximumDistance(forLength: original.count)
        let originalMask = Self.letterMask(original)

        var possibleFirstLetters: Set<Character> = [firstLetter]
        for character in "abcdefghijklmnopqrstuvwxyz"
        where SwipeWordDecoder.areNeighbors(firstLetter, character) {
            possibleFirstLetters.insert(character)
        }

        var results = Set<String>()
        let lowerBound = max(1, original.count - maximumDistance)
        for length in lowerBound...(original.count + maximumDistance) {
            for first in possibleFirstLetters {
                let entries = entriesByBucket[BucketKey(length: length, firstLetter: first)] ?? []
                for entry in entries {
                    // A letter present in one word and absent from the other
                    // costs at least one edit, so this is a sound lower bound.
                    let missingFromCandidate = (originalMask & ~entry.mask).nonzeroBitCount
                    let missingFromOriginal = (entry.mask & ~originalMask).nonzeroBitCount
                    guard max(missingFromCandidate, missingFromOriginal) <= maximumDistance,
                          KeyboardEditingRules.correctionDistance(
                            original,
                            entry.word
                          ) <= maximumDistance else { continue }
                    results.insert(entry.word)
                }
            }
        }
        return results
    }

    private static func maximumDistance(forLength length: Int) -> Int {
        length >= 8 ? 3 : (length >= 4 ? 2 : 1)
    }

    private static func letterMask(_ word: String) -> UInt32 {
        var mask: UInt32 = 0
        for scalar in word.unicodeScalars where scalar.value >= 97 && scalar.value <= 122 {
            mask |= UInt32(1) << (scalar.value - 97)
        }
        return mask
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
