import UIKit

struct KeyboardCorrection: Equatable, Hashable, Sendable {
    let text: String
    let automaticallyReplaces: Bool
    /// A completion extends a partially typed word rather than repairing it.
    /// It is never applied automatically.
    let isCompletion: Bool

    init(text: String, automaticallyReplaces: Bool, isCompletion: Bool = false) {
        self.text = text
        self.automaticallyReplaces = automaticallyReplaces
        self.isCompletion = isCompletion
    }
}

/// A private, on-device correction engine for the keyboard extension.
///
/// This is an `actor` on purpose. It previously ran on the main actor and was
/// invoked after every keystroke, where it walked whole length buckets of a
/// 20,000-word lexicon computing full edit-distance matrices — thousands of
/// dynamic-programming runs per character, on the thread responsible for
/// receiving touches. Candidate generation now happens off the main thread,
/// behind a cheap bitmask prefilter, and the result is delivered back
/// asynchronously.
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

    /// Everything parsed from the bundled data files.
    ///
    /// Bigrams are held as a sorted table of packed word-index pairs rather
    /// than `[String: [String: Int64]]`. At 236,859 pairs the dictionary form
    /// costs roughly 9 MB in String allocations and hash buckets; two parallel
    /// arrays cost about 2.8 MB with no per-entry overhead. That difference
    /// matters inside a keyboard extension's memory budget.
    private struct Lexicon {
        let frequencies: [String: Int64]
        let wordIndex: [String: UInt32]
        let entriesByBucket: [BucketKey: [LexiconEntry]]
        let bigramKeys: [UInt64]
        let bigramLogFrequencies: [Float]

        static let empty = Lexicon(
            frequencies: [:],
            wordIndex: [:],
            entriesByBucket: [:],
            bigramKeys: [],
            bigramLogFrequencies: []
        )
    }

    private let checker = UITextChecker()
    private var lexicon: Lexicon?
    private var loadTask: Task<Lexicon, Never>?

    /// Words the user rejected a correction for, most-recent-last so trimming
    /// drops the oldest rather than an arbitrary slice of an unordered set.
    private var protectedWords: [String]
    private var protectedWordLookup: Set<String>
    /// Names and shortcuts from `UILexicon`. Kept apart from `protectedWords`
    /// so they are never written into the user's persisted rejection list.
    private var userLexiconWords: Set<String> = []
    private var userLexiconCandidates: [String] = []
    private var acceptedCorrections: [String: Int]
    private let defaults: UserDefaults

    private static let rejectedWordsKey = "keyboard.autocorrect.rejectedWords.v2"
    private static let acceptedCorrectionsKey = "keyboard.autocorrect.acceptedPairs.v2"
    private static let maximumProtectedWords = 512
    private static let maximumSuggestions = 3
    private static let minimumLengthForCompletions = 3

    /// Contacts and shortcuts carry no corpus frequency, so they are scored as
    /// though they were a moderately common word — roughly rank 2,000. High
    /// enough to compete with ordinary vocabulary, not so high that every slip
    /// turns into somebody's name. Repeated acceptance raises them further
    /// through `acceptedCorrections`.
    private static let userLexiconFrequency: Int64 = 20_000_000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedProtected = defaults.stringArray(forKey: Self.rejectedWordsKey) ?? []
        protectedWords = storedProtected
        protectedWordLookup = Set(storedProtected)
        acceptedCorrections = defaults.dictionary(forKey: Self.acceptedCorrectionsKey) as? [String: Int] ?? [:]
    }

    /// Test seam: install a lexicon directly instead of reading the bundle.
    init(
        words: [(word: String, frequency: Int64)],
        bigrams: [(first: String, second: String, frequency: Int64)],
        defaults: UserDefaults
    ) {
        self.defaults = defaults
        let storedProtected = defaults.stringArray(forKey: Self.rejectedWordsKey) ?? []
        protectedWords = storedProtected
        protectedWordLookup = Set(storedProtected)
        acceptedCorrections = defaults.dictionary(forKey: Self.acceptedCorrectionsKey) as? [String: Int] ?? [:]
        lexicon = Self.makeLexicon(words: words, bigrams: bigrams)
    }

    // MARK: - Loading

    /// The bundled files are parsed on first use, off the main thread. Building
    /// them in `init` blocked `viewDidLoad`, delaying the keyboard's first
    /// frame behind ~250,000 lines of parsing.
    private func loadedLexicon() async -> Lexicon {
        if let lexicon { return lexicon }
        if let loadTask { return await loadTask.value }
        let task = Task.detached(priority: .userInitiated) { Self.loadFromBundle() }
        loadTask = task
        let result = await task.value
        lexicon = result
        loadTask = nil
        return result
    }

    func prepare() async {
        _ = await loadedLexicon()
    }

    func updateSupplementaryLexicon(entries: [KeyboardUserLexiconEntry]) {
        for entry in entries {
            for value in [entry.userInput, entry.documentText] {
                let normalized = value.lowercased()
                guard !normalized.isEmpty else { continue }
                userLexiconWords.insert(normalized)
                // Only single words can stand in as a correction candidate;
                // an expansion like "on my way" is protection-only.
                if KeyboardEditingRules.isWordSafeCorrectionCandidate(normalized),
                   normalized.count >= 2,
                   !userLexiconCandidates.contains(normalized) {
                    userLexiconCandidates.append(normalized)
                }
            }
        }
    }

    // MARK: - Corrections

    func corrections(
        for word: String,
        contextBefore: String?,
        language: String,
        evidence: [KeyboardTapEvidence]
    ) async -> [KeyboardCorrection] {
        let original = word.lowercased()
        guard original.count >= 2, language.lowercased().hasPrefix("en") else { return [] }
        let lexicon = await loadedLexicon()

        let isProtected = protectedWordLookup.contains(original)
            || userLexiconWords.contains(original)
        let previousWord = KeyboardEditingRules.wordBeforeAutocorrectionWord(
            contextBefore: contextBefore
        )?.lowercased()
        let spelling = spellingResult(for: word, language: language)
        let systemRanks = Dictionary(
            spelling.suggestions.enumerated().map { ($0.element.lowercased(), $0.offset) },
            uniquingKeysWith: min
        )

        var candidateWords = Set(systemRanks.keys)
        candidateWords.formUnion(lexiconCandidates(for: original, in: lexicon))
        candidateWords.formUnion(userLexiconMatches(for: original))
        candidateWords.remove(original)

        let maximumDistance = Self.maximumDistance(forLength: original.count)
        let candidates = candidateWords.compactMap { candidate -> KeyboardCorrectionCandidate? in
            guard KeyboardEditingRules.isWordSafeCorrectionCandidate(candidate) else { return nil }
            let distance = KeyboardEditingRules.correctionDistance(original, candidate)
            guard distance <= maximumDistance else { return nil }

            let isUserWord = userLexiconWords.contains(candidate)
            let frequency = lexicon.frequencies[candidate]
                ?? (isUserWord ? Self.userLexiconFrequency : 1)

            return KeyboardCorrectionCandidate(
                word: candidate,
                distance: distance,
                frequency: frequency,
                bigramFrequency: previousWord.map {
                    Self.bigramFrequency(first: $0, second: candidate, in: lexicon)
                } ?? 0,
                systemRank: systemRanks[candidate],
                spatialCost: KeyboardCorrectionRanking.spatialCost(
                    original: original,
                    candidate: candidate,
                    evidence: evidence
                ),
                acceptedCount: acceptedCorrections[Self.pairKey(original, candidate)] ?? 0,
                changesFirstLetter: original.first != candidate.first
            )
        }

        let ranked = KeyboardCorrectionRanking.rank(candidates)
        let decision = KeyboardCorrectionRanking.decision(
            original: original,
            originalIsKnownWord: !spelling.isMisspelled || lexicon.frequencies[original] != nil,
            isProtected: isProtected,
            ranked: ranked
        )

        var suggestions: [KeyboardCorrection] = []
        if decision != .none {
            suggestions = ranked.prefix(Self.maximumSuggestions).enumerated().map { index, candidate in
                KeyboardCorrection(
                    text: candidate.word,
                    automaticallyReplaces: index == 0 && decision == .autoReplace
                )
            }
        }

        // Fill any remaining room with completions of what has been typed so
        // far. These extend the word rather than repairing it, so they are
        // offered for an explicit tap and never applied on a delimiter.
        if suggestions.count < Self.maximumSuggestions {
            let taken = Set(suggestions.map(\.text) + [original])
            for completion in completions(for: word, language: language, in: lexicon)
            where !taken.contains(completion) {
                suggestions.append(
                    KeyboardCorrection(
                        text: completion,
                        automaticallyReplaces: false,
                        isCompletion: true
                    )
                )
                if suggestions.count == Self.maximumSuggestions { break }
            }
        }
        return suggestions
    }

    /// `UITextChecker.completions(forPartialWordRange:)` — the one part of
    /// Apple's text-input stack we were not using at all. Ordered by our own
    /// frequency data, since the system returns them alphabetically.
    private func completions(
        for word: String,
        language: String,
        in lexicon: Lexicon
    ) -> [String] {
        guard word.count >= Self.minimumLengthForCompletions else { return [] }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let raw = checker.completions(
            forPartialWordRange: range,
            in: word,
            language: language
        ) ?? []
        let lowercasedOriginal = word.lowercased()
        return raw
            .map { $0.lowercased() }
            .filter {
                $0 != lowercasedOriginal
                    && KeyboardEditingRules.isWordSafeCorrectionCandidate($0)
            }
            .sorted { lhs, rhs in
                let lhsFrequency = lexicon.frequencies[lhs] ?? 0
                let rhsFrequency = lexicon.frequencies[rhs] ?? 0
                if lhsFrequency != rhsFrequency { return lhsFrequency > rhsFrequency }
                return lhs.count < rhs.count
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
            protectedWords.removeFirst(protectedWords.count - Self.maximumProtectedWords)
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
            in: word, range: range, startingAt: 0, wrap: false, language: language
        )
        guard misspelledRange.location != NSNotFound,
              misspelledRange.length == range.length else {
            return (false, [])
        }
        return (true, checker.guesses(forWordRange: range, in: word, language: language) ?? [])
    }

    private func userLexiconMatches(for original: String) -> Set<String> {
        let maximumDistance = Self.maximumDistance(forLength: original.count)
        return Set(
            userLexiconCandidates.filter {
                abs($0.count - original.count) <= maximumDistance
                    && KeyboardEditingRules.correctionDistance(original, $0) <= maximumDistance
            }
        )
    }

    /// Collects plausible lexicon words without running edit distance against
    /// every entry. The bitmask test below is two instructions and removes the
    /// overwhelming majority of a bucket before any matrix is allocated.
    private func lexiconCandidates(for original: String, in lexicon: Lexicon) -> Set<String> {
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
                let entries = lexicon.entriesByBucket[
                    BucketKey(length: length, firstLetter: first)
                ] ?? []
                for entry in entries {
                    // A letter present in one word and absent from the other
                    // costs at least one edit, so this is a sound lower bound.
                    let missingFromCandidate = (originalMask & ~entry.mask).nonzeroBitCount
                    let missingFromOriginal = (entry.mask & ~originalMask).nonzeroBitCount
                    guard max(missingFromCandidate, missingFromOriginal) <= maximumDistance,
                          KeyboardEditingRules.correctionDistance(
                            original, entry.word
                          ) <= maximumDistance else { continue }
                    results.insert(entry.word)
                }
            }
        }
        return results
    }

    // MARK: - Bigrams

    private static func bigramFrequency(
        first: String,
        second: String,
        in lexicon: Lexicon
    ) -> Int64 {
        guard let firstIndex = lexicon.wordIndex[first],
              let secondIndex = lexicon.wordIndex[second] else { return 0 }
        let key = UInt64(firstIndex) << 32 | UInt64(secondIndex)

        var low = 0
        var high = lexicon.bigramKeys.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let probe = lexicon.bigramKeys[mid]
            if probe == key {
                // Stored as a log to halve the table; the score takes a log
                // anyway, so the round trip loses nothing that matters.
                return Int64(max(0, pow(10, Double(lexicon.bigramLogFrequencies[mid])) - 1))
            }
            if probe < key { low = mid + 1 } else { high = mid - 1 }
        }
        return 0
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

    // MARK: - Parsing

    private static func loadFromBundle() -> Lexicon {
        makeLexicon(
            words: loadFrequencyWords(),
            bigramData: bundledData(named: "AutocorrectBigrams")
        )
    }

    private static func makeLexicon(
        words: [(word: String, frequency: Int64)],
        bigrams: [(first: String, second: String, frequency: Int64)]
    ) -> Lexicon {
        let base = makeLexicon(words: words, bigramData: nil)
        var keyed: [(UInt64, Float)] = []
        for bigram in bigrams {
            guard let first = base.wordIndex[bigram.first],
                  let second = base.wordIndex[bigram.second] else { continue }
            keyed.append(
                (UInt64(first) << 32 | UInt64(second),
                 Float(log10(Double(max(bigram.frequency, 0)) + 1)))
            )
        }
        keyed.sort { $0.0 < $1.0 }
        return Lexicon(
            frequencies: base.frequencies,
            wordIndex: base.wordIndex,
            entriesByBucket: base.entriesByBucket,
            bigramKeys: keyed.map(\.0),
            bigramLogFrequencies: keyed.map(\.1)
        )
    }

    private static func makeLexicon(
        words: [(word: String, frequency: Int64)],
        bigramData: Data?
    ) -> Lexicon {
        var frequencies: [String: Int64] = [:]
        var wordIndex: [String: UInt32] = [:]
        var buckets: [BucketKey: [LexiconEntry]] = [:]
        frequencies.reserveCapacity(words.count)
        wordIndex.reserveCapacity(words.count)

        for (offset, entry) in words.enumerated() {
            frequencies[entry.word] = max(frequencies[entry.word] ?? 0, entry.frequency)
            if wordIndex[entry.word] == nil {
                wordIndex[entry.word] = UInt32(offset)
            }
            guard let firstLetter = entry.word.first else { continue }
            buckets[
                BucketKey(length: entry.word.count, firstLetter: firstLetter),
                default: []
            ].append(
                LexiconEntry(
                    word: entry.word,
                    frequency: entry.frequency,
                    mask: letterMask(entry.word)
                )
            )
        }

        var keys: [UInt64] = []
        var logs: [Float] = []
        if let bigramData {
            (keys, logs) = parseBigrams(bigramData, wordIndex: wordIndex)
        }
        return Lexicon(
            frequencies: frequencies,
            wordIndex: wordIndex,
            entriesByBucket: buckets,
            bigramKeys: keys,
            bigramLogFrequencies: logs
        )
    }

    /// Byte-level scan rather than `String.split`. At a quarter of a million
    /// lines the Swift string machinery dominates the parse; walking the bytes
    /// directly and reusing the first word across its run of lines (the file is
    /// sorted, so 236,859 lines carry only 14,048 distinct first words) keeps
    /// this well under a tenth of the cost.
    private static func parseBigrams(
        _ data: Data,
        wordIndex: [String: UInt32]
    ) -> (keys: [UInt64], logs: [Float]) {
        var pairs: [(UInt64, Float)] = []
        pairs.reserveCapacity(wordIndex.count * 8)

        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            var index = 0
            var cachedFirst: (bytes: [UInt8], value: UInt32?)?

            while index < count {
                let lineStart = index
                while index < count, base[index] != 0x0A { index += 1 }
                let lineEnd = index
                index += 1
                guard lineEnd > lineStart else { continue }

                var cursor = lineStart
                while cursor < lineEnd, base[cursor] != 0x20 { cursor += 1 }
                let firstEnd = cursor
                guard firstEnd < lineEnd else { continue }
                cursor += 1
                let secondStart = cursor
                while cursor < lineEnd, base[cursor] != 0x20 { cursor += 1 }
                let secondEnd = cursor
                guard secondEnd < lineEnd else { continue }
                cursor += 1

                var frequency: Int64 = 0
                var sawDigit = false
                while cursor < lineEnd, base[cursor] >= 0x30, base[cursor] <= 0x39 {
                    frequency = frequency * 10 + Int64(base[cursor] - 0x30)
                    sawDigit = true
                    cursor += 1
                }
                guard sawDigit else { continue }

                let firstBytes = Array(UnsafeBufferPointer(start: base + lineStart,
                                                           count: firstEnd - lineStart))
                if cachedFirst?.bytes != firstBytes {
                    let word = String(decoding: firstBytes, as: UTF8.self)
                    cachedFirst = (firstBytes, wordIndex[word])
                }
                guard let firstValue = cachedFirst?.value else { continue }

                let secondWord = String(
                    decoding: UnsafeBufferPointer(start: base + secondStart,
                                                  count: secondEnd - secondStart),
                    as: UTF8.self
                )
                guard let secondValue = wordIndex[secondWord] else { continue }

                pairs.append(
                    (UInt64(firstValue) << 32 | UInt64(secondValue),
                     Float(log10(Double(frequency) + 1)))
                )
            }
        }

        pairs.sort { $0.0 < $1.0 }
        return (pairs.map(\.0), pairs.map(\.1))
    }

    private static func bundledData(named name: String) -> Data? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else {
            return nil
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
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
}
