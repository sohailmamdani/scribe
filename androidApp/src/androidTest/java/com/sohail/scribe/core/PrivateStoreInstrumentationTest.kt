package com.sohail.scribe.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PrivateStoreInstrumentationTest {
    @Test fun keyboardPreferencesRoundTripAndReset() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.getSharedPreferences("scribe.preferences", 0).edit().clear().commit()
        val store = ScribePreferences(context)
        val changed = KeyboardPreferences(
            alternateSymbolsEnabled = false,
            alternateHoldDelayMillis = 400,
            symbolTapBehavior = SymbolTapBehavior.RETURN_TO_LETTERS,
            symbolTapScope = SymbolTapScope.SYMBOLS_ONLY,
            keyPreviewsEnabled = false,
            hapticsEnabled = false,
            doubleSpacePeriodEnabled = false,
            autocorrectionEnabled = false,
            swipeTypingEnabled = false,
            enhancedPunctuationEnabled = false,
        )
        store.keyboard = changed
        assertEquals(changed, ScribePreferences(context).keyboard)
        store.resetKeyboard()
        assertEquals(KeyboardPreferences(), ScribePreferences(context).keyboard)
    }

    @Test fun historyPersistsDeduplicatesAndClears() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = DictationHistoryStore(context)
        store.clear()
        val first = store.add(" private words ")
        val replacement = store.add("private words")
        assertNotEquals(first?.id, replacement?.id)
        assertEquals(listOf("private words"), DictationHistoryStore(context).load().map { it.text })
        store.clear()
        assertEquals(emptyList<DictationHistoryItem>(), store.load())
    }

    @Test fun recoverableDictationPersistsConsumesDiscardsAndExpires() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var now = 1_000_000L
        val store = RecoverableDictationStore(context) { now }
        store.discard()

        store.save(" finished words ")
        assertEquals("finished words", RecoverableDictationStore(context) { now }.load())
        assertEquals("finished words", store.consume())
        assertEquals(null, store.load())

        store.save("discard me")
        store.discard()
        assertEquals(null, store.load())

        store.save("expired words")
        now += 15 * 60 * 1_000L + 1
        assertEquals(null, store.load())
    }
}
