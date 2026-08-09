package com.sohail.scribe.core

object TranscriptPolisher {
    private val silenceMarker = Regex("""(?i)\[\s*(?:blank[\s_-]*audio|no[\s_-]*speech)\s*]""")
    private val filler = Regex("""(?i)(^|[\s,])(um+|uh+|erm+|hmm+)(?=([\s,]|$))""")
    private val repeatedWord = Regex("""(?i)\b([\p{L}\p{N}']+)(?:\s+\1\b)+""")
    private val punctuationGap = Regex("""\s+([,.!?;:])""")
    private val whitespace = Regex("""\s+""")

    fun polish(rawText: String): String {
        var text = rawText
            .replace(silenceMarker, " ")
            .replace(whitespace, " ")
            .trim()
            .replace(filler, "$1")
            .replace(repeatedWord, "$1")
            .replace(punctuationGap, "$1")
            .replace(whitespace, " ")
            .trim()
        val firstLetter = text.indexOfFirst(Char::isLetter)
        if (firstLetter >= 0) {
            text = text.replaceRange(
                firstLetter,
                firstLetter + 1,
                text[firstLetter].uppercase(),
            )
        }
        return text
    }

    fun comparableWords(text: String): List<String> = text
        .split(Regex("""[^\p{L}\p{N}'’]+"""))
        .map { it.replace('’', '\'').lowercase() }
        .filter(String::isNotEmpty)

    fun isFaithfulRefinement(refined: String, original: String): Boolean {
        val refinedWords = comparableWords(refined)
        val originalWords = comparableWords(original)
        if (refinedWords.isEmpty() || refinedWords.size > originalWords.size) return false
        var originalIndex = 0
        for (word in refinedWords) {
            while (originalIndex < originalWords.size && originalWords[originalIndex] != word) {
                originalIndex++
            }
            if (originalIndex == originalWords.size) return false
            originalIndex++
        }
        return true
    }

    fun textForInsertion(transcript: String, before: CharSequence?, after: CharSequence?): String {
        if (transcript.isEmpty()) return ""
        val leading = before?.lastOrNull()?.let { !it.isWhitespace() && it !in "([{\n" } ?: false
        val trailing = after?.firstOrNull()?.let { !it.isWhitespace() && it !in ".,!?;:)]}" } ?: true
        return buildString {
            if (leading) append(' ')
            append(transcript)
            if (trailing) append(' ')
        }
    }
}
