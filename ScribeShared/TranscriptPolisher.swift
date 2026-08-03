import Foundation

enum TranscriptPolisher {
    static func polish(_ rawText: String) -> String {
        var text = rawText
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
