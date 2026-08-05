import Foundation

enum TranscriptPolisher {
    static func polish(_ rawText: String) -> String {
        var text = rawText
            .replacingOccurrences(
                of: #"(?i)\[\s*(?:blank[\s_-]*audio|no[\s_-]*speech)\s*\]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Keep this intentionally conservative. Model punctuation is preserved,
        // while the most common spoken fillers and accidental word repeats go away.
        text = text.replacingOccurrences(
            of: #"(?i)(^|[\s,])(um+|uh+|erm+|hmm+)(?=([\s,]|$))"#,
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?i)\b([\p{L}\p{N}']+)(?:\s+\1\b)+"#,
            with: "$1",
            options: .regularExpression
        )
        text = text
            .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let firstLetter = text.firstIndex(where: { $0.isLetter }) else { return text }
        text.replaceSubrange(firstLetter...firstLetter, with: String(text[firstLetter]).uppercased())
        return text
    }

    /// Guards a language-model refinement against the model doing more than it
    /// was asked to.
    ///
    /// Polishing may only drop words (fillers, stutters) and change punctuation
    /// or casing. So every word the model returns must already appear in the
    /// transcript, in the same order — the output has to be a subsequence of
    /// the input. That rejects invented content, substituted words, reordering,
    /// and answering the transcript instead of cleaning it, which is the whole
    /// risk of putting a generative model on this path.
    ///
    /// It also rejects benign rewrites such as "gonna" into "going to". That is
    /// the intended trade: when in doubt, keep the deterministic result.
    static func isFaithfulRefinement(_ refined: String, of original: String) -> Bool {
        let refinedWords = comparableWords(refined)
        guard !refinedWords.isEmpty else { return false }
        let originalWords = comparableWords(original)
        guard refinedWords.count <= originalWords.count else { return false }

        var index = originalWords.startIndex
        for word in refinedWords {
            guard let match = originalWords[index...].firstIndex(of: word) else { return false }
            index = originalWords.index(after: match)
        }
        return true
    }

    /// Words reduced to letters and digits, lowercased, so punctuation and
    /// capitalization changes do not register as content changes.
    static func comparableWords(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .map { $0.replacingOccurrences(of: "’", with: "'").lowercased() }
            .filter { !$0.isEmpty }
    }

    static func textForInsertion(
        _ transcript: String,
        contextBefore: String?,
        contextAfter: String?
    ) -> String {
        guard !transcript.isEmpty else { return "" }

        let before = contextBefore ?? ""
        let after = contextAfter ?? ""
        let needsLeadingSpace = before.last.map { !$0.isWhitespace && !"([{\n".contains($0) } ?? false
        let needsTrailingSpace = after.first.map { !$0.isWhitespace && !".,!?;:)]}".contains($0) } ?? true

        return (needsLeadingSpace ? " " : "")
            + transcript
            + (needsTrailingSpace ? " " : "")
    }
}
