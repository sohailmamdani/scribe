package com.sohail.scribe.keyboard

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class KeyboardLexiconTest {
    @Test fun distanceSupportsAdjacentTransposition() {
        assertEquals(1, KeyboardLexicon.correctionDistance("teh", "the"))
        assertEquals(1, KeyboardLexicon.correctionDistance("helo", "hello"))
        assertEquals(3, KeyboardLexicon.correctionDistance("cat", "dog"))
    }

    @Test fun capitalizationIsConservative() {
        assertEquals("Hello", KeyboardLexicon.matchCapitalization("hello", "Helo"))
        assertEquals("hello", KeyboardLexicon.matchCapitalization("hello", "helo"))
        assertTrue(KeyboardLexicon.matchCapitalization("i'm", "im").startsWith("I"))
    }
}
