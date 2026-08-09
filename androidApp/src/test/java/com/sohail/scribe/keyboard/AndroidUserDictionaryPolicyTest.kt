package com.sohail.scribe.keyboard

import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AndroidUserDictionaryPolicyTest {
    @Test fun currentLanguageAndLanguageNeutralRowsBecomePrivateKeyboardCandidates() {
        val snapshot = AndroidUserDictionaryPolicy.snapshot(
            rows = listOf(
                AndroidUserDictionaryRow("Sohail", null, 180, "en_US"),
                AndroidUserDictionaryRow("OpenAI", "oai", 220, "en-GB"),
                AndroidUserDictionaryRow("globalword", null, 40, null),
                AndroidUserDictionaryRow("bonjour", null, 255, "fr_FR"),
            ),
            activeLocale = Locale.US,
        )

        assertTrue("sohail" in snapshot.protectedWords)
        assertTrue("openai" in snapshot.candidateFrequencies)
        assertTrue("oai" in snapshot.candidateFrequencies)
        assertTrue("globalword" in snapshot.candidateFrequencies)
        assertFalse("bonjour" in snapshot.protectedWords)
    }

    @Test fun multiwordExpansionsAreProtectedButNeverOfferedAsSingleWordCorrections() {
        val snapshot = AndroidUserDictionaryPolicy.snapshot(
            rows = listOf(
                AndroidUserDictionaryRow("On my way", "omw", 300, "en_US"),
                AndroidUserDictionaryRow("OMW", null, 10, "en_US"),
            ),
            activeLocale = Locale.US,
        )

        assertTrue("on my way" in snapshot.protectedWords)
        assertFalse("on my way" in snapshot.candidateFrequencies)
        assertEquals(20_000_255L, snapshot.candidateFrequencies["omw"])
    }
}
