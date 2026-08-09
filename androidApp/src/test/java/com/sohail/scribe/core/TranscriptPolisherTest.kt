package com.sohail.scribe.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TranscriptPolisherTest {
    @Test fun removesOnlyKnownSilenceMarkersAndFillers() {
        assertEquals(
            "Hello world.",
            TranscriptPolisher.polish(" [BLANK_AUDIO] um hello hello world . "),
        )
        assertEquals("Keep [stage direction]", TranscriptPolisher.polish("keep [stage direction]"))
    }

    @Test fun contextualInsertionPreservesPunctuationSpacing() {
        assertEquals(" hello ", TranscriptPolisher.textForInsertion("hello", "Say", "world"))
        assertEquals("Hello ", TranscriptPolisher.textForInsertion("Hello", null, null))
        assertEquals("Hello", TranscriptPolisher.textForInsertion("Hello", "(", ")"))
    }

    @Test fun faithfulRefinementRejectsNewOrReorderedWords() {
        assertTrue(TranscriptPolisher.isFaithfulRefinement("Hello, world!", "hello um world"))
        assertFalse(TranscriptPolisher.isFaithfulRefinement("Hello bright world", "hello world"))
        assertFalse(TranscriptPolisher.isFaithfulRefinement("World hello", "hello world"))
    }
}
