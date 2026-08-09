package com.sohail.scribe.keyboard

import com.sohail.scribe.core.KeyboardEditingRules

internal object KeyboardDelimiterCorrectionPolicy {
    fun replacement(
        original: String,
        suggestionWord: String?,
        candidates: List<CorrectionCandidate>,
        protectedWords: Set<String>,
    ): String? {
        val normalized = original.lowercase()
        if (normalized in protectedWords) return null

        candidates
            .takeIf { suggestionWord.equals(original, ignoreCase = true) }
            ?.firstOrNull(CorrectionCandidate::automaticallyReplaces)
            ?.text
            ?.let { return it }

        val contraction = KeyboardEditingRules.preferredContraction(normalized) ?: return null
        return KeyboardLexicon.matchCapitalization(contraction, original)
    }
}
