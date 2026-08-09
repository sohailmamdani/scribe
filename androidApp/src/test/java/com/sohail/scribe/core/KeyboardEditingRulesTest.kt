package com.sohail.scribe.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class KeyboardEditingRulesTest {
    @Test fun swipeWordsInsertOnlyTheLeadingBoundaryTheyNeed() {
        assertTrue(KeyboardEditingRules.needsLeadingSpaceAfter('d'))
        assertTrue(KeyboardEditingRules.needsLeadingSpaceAfter(')'))
        listOf(' ', '\n', '(', '[', '{', '\"', '\'', '“', '‘', '@', '#', '$', '/', '_', '-', '–', '—')
            .forEach { assertFalse(KeyboardEditingRules.needsLeadingSpaceAfter(it), "Unexpected space after $it") }
    }

    @Test fun currentWordKeepsApostrophes() {
        assertEquals("isn't", KeyboardEditingRules.currentWord("That isn't"))
        assertEquals(null, KeyboardEditingRules.currentWord("a"))
        assertEquals(null, KeyboardEditingRules.currentWord("done "))
    }

    @Test fun previousWordSkipsCurrentWordAndDelimiters() {
        assertEquals("hello", KeyboardEditingRules.previousWord("hello brave"))
        assertEquals("don't", KeyboardEditingRules.previousWord("don't  worry"))
        assertEquals(null, KeyboardEditingRules.previousWord("single"))
    }

    @Test fun onlyUnambiguousContractionsAreRestored() {
        assertEquals("can't", KeyboardEditingRules.preferredContraction("cant"))
        assertEquals("I'm", KeyboardEditingRules.preferredContraction("IM"))
        assertEquals(null, KeyboardEditingRules.preferredContraction("well"))
    }

    @Test fun sentenceCapitalizationUsesNearbyContext() {
        assertTrue(KeyboardEditingRules.shouldCapitalize(null))
        assertTrue(KeyboardEditingRules.shouldCapitalize("Hello! "))
        assertFalse(KeyboardEditingRules.shouldCapitalize("Hello "))
    }

    @Test fun wordCapitalizationTracksWhitespace() {
        assertTrue(KeyboardEditingRules.shouldCapitalizeWord(null))
        assertTrue(KeyboardEditingRules.shouldCapitalizeWord("hello "))
        assertFalse(KeyboardEditingRules.shouldCapitalizeWord("hello"))
    }

    @Test fun doubleSpaceRequiresWordLikePredecessor() {
        assertTrue(KeyboardEditingRules.shouldReplaceDoubleSpace("hello ", 400))
        assertFalse(KeyboardEditingRules.shouldReplaceDoubleSpace("hello ", 551))
        assertFalse(KeyboardEditingRules.shouldReplaceDoubleSpace("hello", 100))
        assertFalse(KeyboardEditingRules.shouldReplaceDoubleSpace("( ", 100))
        assertFalse(KeyboardEditingRules.shouldReplaceDoubleSpace("hello "))
    }

    @Test fun wordDeleteConsumesTrailingWhitespaceThenOneWordInCodePoints() {
        assertEquals(6, KeyboardEditingRules.deleteWordCodePointCount("hello "))
        assertEquals(5, KeyboardEditingRules.deleteWordCodePointCount("hello brave"))
        assertEquals(1, KeyboardEditingRules.deleteWordCodePointCount("go 👍"))
        assertEquals(1, KeyboardEditingRules.deleteWordCodePointCount(""))
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
