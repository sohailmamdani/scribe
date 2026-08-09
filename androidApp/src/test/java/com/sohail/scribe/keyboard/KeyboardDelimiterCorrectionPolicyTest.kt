package com.sohail.scribe.keyboard

import kotlin.test.Test
import kotlin.test.assertEquals

class KeyboardDelimiterCorrectionPolicyTest {
    @Test fun fastDelimiterStillRestoresUnambiguousContractions() {
        listOf(
            "dont" to "don't",
            "Dont" to "Don't",
            "im" to "I'm",
        ).forEach { (original, expected) ->
            assertEquals(
                expected,
                KeyboardDelimiterCorrectionPolicy.replacement(
                    original = original,
                    suggestionWord = null,
                    candidates = emptyList(),
                    protectedWords = emptySet(),
                ),
            )
        }
    }

    @Test fun matchingAutomaticCandidateWinsWhileStaleAndProtectedWordsDoNotReplace() {
        val automatic = CorrectionCandidate("water", automaticallyReplaces = true)
        assertEquals(
            "water",
            KeyboardDelimiterCorrectionPolicy.replacement(
                original = "watre",
                suggestionWord = "watre",
                candidates = listOf(automatic),
                protectedWords = emptySet(),
            ),
        )
        assertEquals(
            null,
            KeyboardDelimiterCorrectionPolicy.replacement(
                original = "watre",
                suggestionWord = "olderword",
                candidates = listOf(automatic),
                protectedWords = emptySet(),
            ),
        )
        assertEquals(
            null,
            KeyboardDelimiterCorrectionPolicy.replacement(
                original = "dont",
                suggestionWord = "dont",
                candidates = listOf(CorrectionCandidate("don't", automaticallyReplaces = true)),
                protectedWords = setOf("dont"),
            ),
        )
    }
}
