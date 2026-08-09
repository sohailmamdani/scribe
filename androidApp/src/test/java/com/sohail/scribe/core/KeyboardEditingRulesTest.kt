package com.sohail.scribe.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class KeyboardEditingRulesTest {
    @Test fun currentWordKeepsApostrophes() {
        assertEquals("isn't", KeyboardEditingRules.currentWord("That isn't"))
        assertEquals(null, KeyboardEditingRules.currentWord("a"))
        assertEquals(null, KeyboardEditingRules.currentWord("done "))
    }

    @Test fun sentenceCapitalizationUsesNearbyContext() {
        assertTrue(KeyboardEditingRules.shouldCapitalize(null))
        assertTrue(KeyboardEditingRules.shouldCapitalize("Hello! "))
        assertFalse(KeyboardEditingRules.shouldCapitalize("Hello "))
    }

    @Test fun doubleSpaceRequiresWordLikePredecessor() {
        assertTrue(KeyboardEditingRules.shouldReplaceDoubleSpace("hello "))
        assertFalse(KeyboardEditingRules.shouldReplaceDoubleSpace("hello"))
        assertFalse(KeyboardEditingRules.shouldReplaceDoubleSpace("( "))
    }

    @Test fun symbolReturnScopeMatchesSettings() {
        assertTrue(
            KeyboardEditingRules.shouldReturnToLetters(
                SymbolTapBehavior.RETURN_TO_LETTERS,
                SymbolTapScope.NUMBERS_AND_SYMBOLS,
                onSymbolsPage = false,
            ),
        )
        assertFalse(
            KeyboardEditingRules.shouldReturnToLetters(
                SymbolTapBehavior.RETURN_TO_LETTERS,
                SymbolTapScope.SYMBOLS_ONLY,
                onSymbolsPage = false,
            ),
        )
        assertTrue(
            KeyboardEditingRules.shouldReturnToLetters(
                SymbolTapBehavior.RETURN_TO_LETTERS,
                SymbolTapScope.SYMBOLS_ONLY,
                onSymbolsPage = true,
            ),
        )
    }
}
