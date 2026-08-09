package com.sohail.scribe.keyboard

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class KeyboardCorrectionRankingTest {
    @Test fun bigramContextCanOutrankRawFrequency() {
        val common = candidate("tea", frequency = 50_000_000)
        val contextual = candidate("the", frequency = 900_000, bigramLogFrequency = 11.25)
        assertEquals("the", KeyboardCorrectionRanking.rank(listOf(common, contextual)).first().word)
    }

    @Test fun learnedAcceptanceRaisesCandidateRank() {
        val unlearned = candidate("sample", frequency = 1_000_000)
        val learned = candidate("simple", frequency = 600_000, acceptedCount = 5)
        assertEquals("simple", KeyboardCorrectionRanking.rank(listOf(unlearned, learned)).first().word)
    }

    @Test fun tapNearCandidateKeyIsCheaperThanUnreachableCandidate() {
        val evidence = listOf(
            KeyboardTapEvidence('d', mapOf('s' to 0.18, 'f' to 1.3)),
        )
        assertEquals(
            0.18,
            KeyboardCorrectionRanking.spatialCost("d", "s", evidence),
            absoluteTolerance = 0.001,
        )
        assertEquals(
            KeyboardCorrectionRanking.UNREACHABLE_SPATIAL_COST,
            KeyboardCorrectionRanking.spatialCost("d", "x", evidence),
        )
    }

    @Test fun ambiguousWinnerSuggestsInsteadOfReplacing() {
        val ranked = KeyboardCorrectionRanking.rank(
            listOf(
                candidate("simple", frequency = 1_000_000),
                candidate("sample", frequency = 900_000),
            ),
        )
        assertFalse(
            KeyboardCorrectionRanking.shouldAutomaticallyReplace(
                original = "smple",
                originalIsKnownWord = false,
                protected = false,
                ranked = ranked,
            ),
        )
    }

    @Test fun clearOneEditWinnerAutoReplacesUnlessProtected() {
        val ranked = KeyboardCorrectionRanking.rank(
            listOf(
                candidate("the", frequency = 200_000_000),
                candidate("ten", frequency = 20),
            ),
        )
        assertTrue(
            KeyboardCorrectionRanking.shouldAutomaticallyReplace(
                original = "teh",
                originalIsKnownWord = false,
                protected = false,
                ranked = ranked,
            ),
        )
        assertFalse(
            KeyboardCorrectionRanking.shouldAutomaticallyReplace(
                original = "teh",
                originalIsKnownWord = false,
                protected = true,
                ranked = ranked,
            ),
        )
    }

    @Test fun firstLetterRewriteCarriesAStablePenalty() {
        val unchanged = candidate("cat", frequency = 10_000, changesFirstLetter = false)
        val changed = candidate("bat", frequency = 10_000, changesFirstLetter = true)
        assertEquals(25.0, KeyboardCorrectionRanking.score(changed) - KeyboardCorrectionRanking.score(unchanged))
    }

    private fun candidate(
        word: String,
        frequency: Long,
        bigramLogFrequency: Double = 0.0,
        acceptedCount: Int = 0,
        changesFirstLetter: Boolean = false,
    ) = RankedCorrectionCandidate(
        word = word,
        distance = 1,
        frequency = frequency,
        bigramLogFrequency = bigramLogFrequency,
        acceptedCount = acceptedCount,
        changesFirstLetter = changesFirstLetter,
    )
}
