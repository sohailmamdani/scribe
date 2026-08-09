package com.sohail.scribe.keyboard

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeyboardCorpusInstrumentationTest {
    @Test fun bundledCorpusSupportsCorrectionsContractionsAndSwipe() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val lexicon = KeyboardLexicon(context)
        val typo = lexicon.corrections("teh")
        assertEquals("the", typo.firstOrNull()?.text?.lowercase())
        assertTrue(typo.first().automaticallyReplaces)

        val contraction = lexicon.corrections("cant")
        assertEquals("can't", contraction.firstOrNull()?.text?.lowercase())
        assertTrue(contraction.first().automaticallyReplaces)

        val contextual = lexicon.corrections("smple", contextBefore = "very smple")
        assertEquals("simple", contextual.firstOrNull()?.text?.lowercase())
        assertTrue(contextual.first().automaticallyReplaces)

        val protected = lexicon.corrections("teh", protectedWords = setOf("teh"))
        assertFalse(protected.any(CorrectionCandidate::automaticallyReplaces))

        val swipe = SwipeWordDecoder(context).decode(listOf('h', 'e', 'l', 'l', 'o'))
        assertEquals("hello", swipe)
    }
}
