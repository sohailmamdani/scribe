package com.sohail.scribe.keyboard

import kotlin.test.Test
import kotlin.test.assertEquals

class KeyboardSwipeInsertionTest {
    @Test fun consecutiveWordsGetALeadingBoundaryWithoutForcedTrailingSpace() {
        assertEquals("hello", KeyboardSwipeInsertion.text("hello", null, false))
        assertEquals(" world", KeyboardSwipeInsertion.text("world", "hello", false))
        assertEquals("world", KeyboardSwipeInsertion.text("world", "hello ", false))
        assertEquals("world", KeyboardSwipeInsertion.text("world", "(", false))
    }

    @Test fun manualOrAutomaticShiftCapitalizesTheDecodedWord() {
        assertEquals("Scribe", KeyboardSwipeInsertion.text("scribe", "", true))
        assertEquals(" Scribe", KeyboardSwipeInsertion.text("scribe", "hello", true))
    }
}
