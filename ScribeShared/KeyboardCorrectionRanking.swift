import Foundation

/// What the user's finger actually did for one typed character.
///
/// Real autocorrect scores candidates against *where you tapped*, not just the
/// letters that came out. Scribe already knows every key's rectangle and the
/// exact touch point, so a mistyped "d" that landed hard against the "s" edge
/// is separable from one struck dead centre — the former should correct freely,
/// the latter should not.
struct KeyboardTapEvidence: Equatable, Sendable {
    /// The character that was committed.
    let character: Character
    /// Distance from the touch point to nearby key centres, in key widths.
    /// The committed key is included, normally near zero.
    let normalizedDistances: [Character: Double]

    init(character: Character, normalizedDistances: [Character: Double]) {
        self.character = character
        self.normalizedDistances = normalizedDistances
    }
}

/// One entry from `UILexicon` — the user's contacts and text shortcuts.
/// `userInput` is what they type, `documentText` what it expands to.
struct KeyboardUserLexiconEntry: Equatable, Hashable, Sendable {
    let userInput: String
    let documentText: String

    init(userInput: String, documentText: String) {
        self.userInput = userInput
        self.documentText = documentText
    }
}

struct KeyboardCorrectionCandidate: Equatable, Sendable {
    let word: String
    let distance: Int
    let frequency: Int64
    let bigramFrequency: Int64
    /// Rank in `UITextChecker`'s guesses, or nil when it did not offer the word.
    let systemRank: Int?
    /// 0 means every differing character was struck right on the candidate's
    /// key. Around 1 means one key width away. Higher is less plausible.
    let spatialCost: Double
    let acceptedCount: Int
    /// Whether the correction rewrites the opening letter.
    let changesFirstLetter: Bool

    init(
        word: String,
        distance: Int,
        frequency: Int64,
        bigramFrequency: Int64,
        systemRank: Int?,
        spatialCost: Double,
        acceptedCount: Int,
        changesFirstLetter: Bool = false
    ) {
        self.word = word
        self.distance = distance
        self.frequency = frequency
        self.bigramFrequency = bigramFrequency
        self.systemRank = systemRank
        self.spatialCost = spatialCost
        self.acceptedCount = acceptedCount
        self.changesFirstLetter = changesFirstLetter
    }
}

enum KeyboardCorrectionDecision: Equatable, Sendable {
    /// Offer nothing.
    case none
    /// Show in the suggestion bar; commit only if the user taps it.
    case suggest
    /// Commit automatically when the word is closed by a delimiter.
    case autoReplace
}

enum KeyboardCorrectionRanking {
    /// Applied when there is no touch evidence for a position — dictation,
    /// swipe, and paste produce text without taps. Deliberately mid-range: it
    /// neither vouches for nor condemns the candidate, leaving the frequency
    /// and dictionary signals to decide.
    static let neutralSpatialCost: Double = 1.0

    /// Applied when a differing character is nowhere near where the user
    /// tapped. Expensive, but not disqualifying — genuine spelling mistakes
    /// (as opposed to slips) look exactly like this.
    static let unreachableSpatialCost: Double = 1.9

    /// How far ahead of the runner-up the winner must be to commit itself
    /// without being asked. This is what stops a confident wrong replacement.
    static let autoReplaceMargin: Double = 18

    /// `UITextChecker` recognition is independent evidence that a one-edit
    /// repair is real. Requiring the full generic margin even in that case made
    /// ordinary typos remain suggestions, despite having a clear winner.
    static let recognizedOneEditAutoReplaceMargin: Double = 10

    /// Longer words earn a second edit, because two slips in nine characters is
    /// ordinary and "definately" → "definitely" is exactly the correction users
    /// expect. Short words do not: at four characters a two-edit jump changes
    /// the word rather than repairing it.
    static let minimumLengthForTwoEditAutoReplace = 6

    /// People rarely miss the opening key of a word, and at the start of a
    /// sentence they have usually just pressed Shift for it deliberately.
    static let firstLetterPenalty: Double = 25

    /// How much a word's corpus frequency counts.
    ///
    /// This was 4, which made frequency almost decorative: for "smple" the
    /// candidates "simple", "sample" and "ample" landed within 3.3 points of
    /// each other even though "simple" is 27× commoner than "ample", and
    /// "ample" led purely because the system spell checker happened to list it
    /// first. Frequency is the single most reliable prior about which word a
    /// person meant, and it is stable — unlike the spell checker's ordering,
    /// which is not reproducible between calls.
    static let frequencyWeight: Double = 20

    static func score(_ candidate: KeyboardCorrectionCandidate) -> Double {
        var score = Double(candidate.distance) * 60
        // Expressed as a signed adjustment so "no tap evidence" reads as zero
        // opinion rather than a 34-point charge. This is presentation only: it
        // shifts every candidate by the same constant, so ranking and margins
        // are identical either way.
        //
        // The real asymmetry it makes visible is unfixed: a same-length swap
        // can earn evidence down to ~0, while an insertion or deletion changes
        // the length and can only ever score neutral. Dropping a letter is the
        // commonest phone typo there is, so it competes about 30 points behind
        // a well-aimed swap. Closing that needs evidence for the *omitted* key
        // — whether the finger passed near it — which is not modelled yet.
        score += (candidate.spatialCost - neutralSpatialCost) * 34
        if candidate.changesFirstLetter { score += firstLetterPenalty }
        score -= log10(Double(max(candidate.frequency, 0)) + 1) * frequencyWeight
        score -= log10(Double(max(candidate.bigramFrequency, 0)) + 1) * 8
        score -= Double(min(candidate.acceptedCount, 12)) * 5
        // A mild nudge, not a veto. The old form charged an absent word 28
        // points — more than the entire spread of the frequency signal — so a
        // word the system checker did not happen to offer could not win.
        score += Double(candidate.systemRank ?? 4) * 2
        return score
    }

    static func rank(
        _ candidates: [KeyboardCorrectionCandidate]
    ) -> [KeyboardCorrectionCandidate] {
        candidates.sorted { lhs, rhs in
            let lhsScore = score(lhs)
            let rhsScore = score(rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            if lhs.frequency != rhs.frequency { return lhs.frequency > rhs.frequency }
            return lhs.word < rhs.word
        }
    }

    /// Decides how far a correction is allowed to go.
    ///
    /// The previous rule demanded the winner also be `UITextChecker`'s *first*
    /// guess. Because candidates are ranked on frequency, bigram, and touch
    /// evidence, the winner usually is not, so automatic correction almost
    /// never fired — the suggestion sat visible in the bar and was never
    /// applied. Confidence is now measured against the runner-up instead.
    static func decision(
        original: String,
        originalIsKnownWord: Bool,
        isProtected: Bool,
        ranked: [KeyboardCorrectionCandidate]
    ) -> KeyboardCorrectionDecision {
        guard !isProtected, let best = ranked.first else { return .none }
        // Never overwrite a word that is genuinely spelled correctly. This is
        // the behaviour people describe as the keyboard "fighting" them.
        guard !originalIsKnownWord else { return .suggest }
        guard KeyboardEditingRules.isWordSafeCorrectionCandidate(best.word),
              original.count >= 3 else {
            return .suggest
        }
        // The candidate has to be a word something recognizes.
        guard best.frequency > 1 || best.systemRank != nil else { return .suggest }

        let margin = ranked.count > 1 ? score(ranked[1]) - score(best) : .infinity

        switch best.distance {
        case 1:
            guard KeyboardEditingRules.shouldAutomaticallyReplace(
                original,
                with: best.word
            ) else { return .suggest }
            let requiredMargin = best.systemRank == nil
                ? autoReplaceMargin
                : recognizedOneEditAutoReplaceMargin
            guard margin >= requiredMargin else { return .suggest }
            return .autoReplace
        case 2:
            guard margin >= autoReplaceMargin,
                  original.count >= minimumLengthForTwoEditAutoReplace,
                  best.spatialCost <= neutralSpatialCost,
                  best.systemRank != nil || best.bigramFrequency > 0 else {
                return .suggest
            }
            return .autoReplace
        default:
            return .suggest
        }
    }

    /// Cost of believing the user meant `candidate` while typing `original`.
    ///
    /// Only equal-length words carry spatial meaning: a substitution maps one
    /// tap to one key. Insertions and deletions are timing errors, not aiming
    /// errors, so they fall through to the neutral cost and are judged on
    /// frequency alone.
    static func spatialCost(
        original: String,
        candidate: String,
        evidence: [KeyboardTapEvidence]
    ) -> Double {
        let originalCharacters = Array(original)
        let candidateCharacters = Array(candidate)
        guard originalCharacters.count == candidateCharacters.count else {
            return neutralSpatialCost
        }

        var total = 0.0
        var differences = 0
        for index in originalCharacters.indices
        where originalCharacters[index] != candidateCharacters[index] {
            differences += 1
            total += cost(
                forPosition: index,
                target: candidateCharacters[index],
                evidence: evidence,
                typed: originalCharacters[index]
            )
        }
        guard differences > 0 else { return 0 }
        return total / Double(differences)
    }

    private static func cost(
        forPosition index: Int,
        target: Character,
        evidence: [KeyboardTapEvidence],
        typed: Character
    ) -> Double {
        guard index < evidence.count else { return neutralSpatialCost }
        let tap = evidence[index]
        // Evidence is only trustworthy if it lines up with the text. Anything
        // that edited the field behind the keyboard's back invalidates it.
        guard tap.character == typed else { return neutralSpatialCost }
        guard let distance = tap.normalizedDistances[target] else {
            return unreachableSpatialCost
        }
        return min(distance, unreachableSpatialCost)
    }
}
