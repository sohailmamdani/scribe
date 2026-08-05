import Foundation

enum KeyboardFieldKind: Equatable, Sendable {
    case text
    case URL
    case email
    case webSearch
    case phone
    case number
    case other

    var supportsDoubleSpacePeriod: Bool {
        self == .text
    }

    var supportsAutocorrection: Bool {
        self == .text || self == .webSearch
    }
}

enum KeyboardCapitalizationMode: Equatable, Sendable {
    case none
    case words
    case sentences
    case allCharacters
}

enum KeyboardShiftState: Equatable, Sendable {
    case off
    case once
    case locked

    var usesUppercase: Bool { self != .off }
}

enum KeyboardEditingRules {
    nonisolated static let rejectedAutocorrectionWordsKey =
        "keyboard.autocorrect.rejectedWords.v2"

    /// Missing-apostrophe forms that are safe enough to restore without
    /// guessing between two ordinary words. Ambiguous spellings such as
    /// `well`/`we'll`, `were`/`we're`, `ill`/`I'll`, and `its`/`it's` are
    /// intentionally absent.
    nonisolated private static let preferredContractions: [String: String] = [
        "aint": "ain't",
        "arent": "aren't",
        "cant": "can't",
        "couldnt": "couldn't",
        "couldve": "could've",
        "didnt": "didn't",
        "doesnt": "doesn't",
        "dont": "don't",
        "hadnt": "hadn't",
        "hasnt": "hasn't",
        "havent": "haven't",
        "heres": "here's",
        "hows": "how's",
        "im": "I'm",
        "isnt": "isn't",
        "itll": "it'll",
        "ive": "I've",
        "mightnt": "mightn't",
        "mightve": "might've",
        "mustnt": "mustn't",
        "mustve": "must've",
        "neednt": "needn't",
        "shes": "she's",
        "shouldnt": "shouldn't",
        "shouldve": "should've",
        "thats": "that's",
        "theres": "there's",
        "theyll": "they'll",
        "theyre": "they're",
        "theyve": "they've",
        "wasnt": "wasn't",
        "werent": "weren't",
        "weve": "we've",
        "whats": "what's",
        "whens": "when's",
        "wheres": "where's",
        "whod": "who'd",
        "wholl": "who'll",
        "whos": "who's",
        "whyd": "why'd",
        "wont": "won't",
        "wouldnt": "wouldn't",
        "wouldve": "would've",
        "yall": "y'all",
        "youll": "you'll",
        "youre": "you're",
        "youve": "you've",
    ]

    nonisolated static func preferredContraction(for word: String) -> String? {
        preferredContractions[word.lowercased()]
    }

    nonisolated static func isRejectedAutocorrectionWord(
        _ word: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let normalized = word.lowercased()
        return defaults.stringArray(forKey: rejectedAutocorrectionWordsKey)?
            .contains(normalized) == true
    }

    static let doubleSpaceInterval: TimeInterval = 0.55

    static func shouldConvertDoubleSpace(
        contextBefore: String?,
        elapsedSincePreviousSpace: TimeInterval?,
        fieldKind: KeyboardFieldKind
    ) -> Bool {
        guard fieldKind.supportsDoubleSpacePeriod,
              let elapsedSincePreviousSpace,
              elapsedSincePreviousSpace >= 0,
              elapsedSincePreviousSpace <= doubleSpaceInterval,
              let contextBefore,
              contextBefore.last == " ",
              let preceding = contextBefore.dropLast().last else {
            return false
        }

        return preceding.isLetter
            || preceding.isNumber
            || ")]}'\"”’".contains(preceding)
    }

    static func automaticShiftState(
        contextBefore: String?,
        capitalization: KeyboardCapitalizationMode
    ) -> KeyboardShiftState {
        switch capitalization {
        case .none:
            return .off
        case .allCharacters:
            return .locked
        case .words:
            guard let contextBefore, let last = contextBefore.last else { return .once }
            return last.isWhitespace ? .once : .off
        case .sentences:
            guard let contextBefore, !contextBefore.isEmpty else { return .once }
            if contextBefore.last == "\n" { return .once }
            let trimmed = contextBefore.drop(whileTrailing: { $0.isWhitespace })
            guard let last = trimmed.last else { return .once }
            return ".!?".contains(last) ? .once : .off
        }
    }

    static func autocorrectionWord(
        contextBefore: String?,
        fieldKind: KeyboardFieldKind,
        autocorrectionEnabled: Bool
    ) -> String? {
        guard autocorrectionEnabled,
              fieldKind.supportsAutocorrection,
              let contextBefore,
              !contextBefore.isEmpty else {
            return nil
        }

        let word = String(
            contextBefore.reversed().prefix { character in
                character.isLetter || character == "'" || character == "’"
            }.reversed()
        )
        guard word.count >= 2,
              word.contains(where: \Character.isLetter),
              !hasUnexpectedCapitalization(word) else {
            return nil
        }
        return word
    }

    static func wordBeforeAutocorrectionWord(contextBefore: String?) -> String? {
        guard var remaining = contextBefore, !remaining.isEmpty else { return nil }
        while let last = remaining.last,
              last.isLetter || last == "'" || last == "’" {
            remaining.removeLast()
        }
        while let last = remaining.last, !last.isLetter {
            remaining.removeLast()
        }
        let word = String(
            remaining.reversed().prefix { character in
                character.isLetter || character == "'" || character == "’"
            }.reversed()
        )
        return word.isEmpty ? nil : word
    }

    static func replacement(_ suggestion: String, matchingCapitalizationOf original: String) -> String? {
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \Character.isWhitespace),
              isWordSafeCorrectionCandidate(trimmed),
              trimmed.caseInsensitiveCompare(original) != .orderedSame else {
            return nil
        }

        // The pronoun I remains capitalized even when the user entered a
        // lowercase missing-apostrophe form such as `im` or `ive`.
        if trimmed.lowercased().hasPrefix("i'") {
            return "I" + trimmed.dropFirst().lowercased()
        }
        if original == original.lowercased() {
            return trimmed.lowercased()
        }
        if original.first?.isUppercase == true,
           original.dropFirst() == original.dropFirst().lowercased() {
            return trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()
        }
        return trimmed
    }

    /// Accepting a suggestion advances to the next word, matching the native
    /// iOS keyboard instead of leaving the caret attached to the replacement.
    static func acceptedSuggestionText(_ replacement: String) -> String {
        replacement + " "
    }

    /// Keeps Apple's spelling candidates in the loop, while using the bundled
    /// frequency lexicon to break close ties. Wildly different words are
    /// removed so they can never be committed from the suggestion bar.
    static func rankedCorrectionSuggestions(
        for original: String,
        suggestions: [String],
        frequencyRanks: [String: Int]
    ) -> [String] {
        let normalizedOriginal = original.lowercased()
        var seen = Set<String>()
        let maximumDistance: Int
        if normalizedOriginal.count >= 8 {
            maximumDistance = 3
        } else if normalizedOriginal.count >= 4 {
            maximumDistance = 2
        } else {
            maximumDistance = 1
        }

        return suggestions.enumerated().compactMap { index, suggestion -> (String, Int)? in
            let normalized = suggestion
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty,
                  !normalized.contains(where: \Character.isWhitespace),
                  normalized != normalizedOriginal,
                  seen.insert(normalized).inserted else {
                return nil
            }

            let distance = correctionDistance(normalizedOriginal, normalized)
            guard distance <= maximumDistance else { return nil }
            let frequencyRank = frequencyRanks[normalized] ?? 50_000
            let frequencyPenalty = Int(log10(Double(frequencyRank) + 1) * 4)
            return (suggestion, distance * 100 + index * 4 + frequencyPenalty)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
        }
        .map(\.0)
    }

    /// Automatic replacement is deliberately conservative. A one-edit typo
    /// (including a transposition such as "teh") is corrected on a delimiter;
    /// broader guesses remain visible for an explicit tap.
    static func shouldAutomaticallyReplace(_ original: String, with suggestion: String) -> Bool {
        let source = original.lowercased()
        let destination = suggestion.lowercased()
        guard source.count >= 3,
              destination.count >= 2,
              isWordSafeCorrectionCandidate(source),
              isWordSafeCorrectionCandidate(destination),
              source != destination else {
            return false
        }
        return correctionDistance(source, destination) == 1
    }

    static func isWordSafeCorrectionCandidate(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { character in
            character.isLetter || character == "'" || character == "’"
        }
    }

    /// Optimal-string-alignment distance: Levenshtein edits plus one adjacent
    /// transposition. That matches the common mobile typo model without
    /// treating arbitrary anagrams as close corrections.
    static func correctionDistance(_ source: String, _ destination: String) -> Int {
        let lhs = Array(source)
        let rhs = Array(destination)
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }

        var rows = Array(
            repeating: Array(repeating: 0, count: rhs.count + 1),
            count: lhs.count + 1
        )
        for index in 0...lhs.count { rows[index][0] = index }
        for index in 0...rhs.count { rows[0][index] = index }

        for leftIndex in 1...lhs.count {
            for rightIndex in 1...rhs.count {
                let substitutionCost = lhs[leftIndex - 1] == rhs[rightIndex - 1] ? 0 : 1
                rows[leftIndex][rightIndex] = min(
                    rows[leftIndex - 1][rightIndex] + 1,
                    rows[leftIndex][rightIndex - 1] + 1,
                    rows[leftIndex - 1][rightIndex - 1] + substitutionCost
                )
                if leftIndex > 1,
                   rightIndex > 1,
                   lhs[leftIndex - 1] == rhs[rightIndex - 2],
                   lhs[leftIndex - 2] == rhs[rightIndex - 1] {
                    rows[leftIndex][rightIndex] = min(
                        rows[leftIndex][rightIndex],
                        rows[leftIndex - 2][rightIndex - 2] + 1
                    )
                }
            }
        }
        return rows[lhs.count][rhs.count]
    }

    private static func hasUnexpectedCapitalization(_ word: String) -> Bool {
        let letters = word.filter(\Character.isLetter)
        guard letters.count > 1 else { return false }
        if letters == letters.uppercased() { return true }
        return letters.dropFirst().contains(where: \Character.isUppercase)
    }
}

private extension String {
    func drop(whileTrailing predicate: (Character) -> Bool) -> Substring {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard predicate(self[previous]) else { break }
            end = previous
        }
        return self[..<end]
    }
}
