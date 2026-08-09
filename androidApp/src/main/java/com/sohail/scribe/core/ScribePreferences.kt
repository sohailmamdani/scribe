package com.sohail.scribe.core

import android.content.Context
import android.content.SharedPreferences

enum class SymbolTapBehavior { STAY, RETURN_TO_LETTERS }
enum class SymbolTapScope { NUMBERS_AND_SYMBOLS, SYMBOLS_ONLY }

data class KeyboardPreferences(
    val alternateSymbolsEnabled: Boolean = true,
    val alternateHoldDelayMillis: Int = 650,
    val symbolTapBehavior: SymbolTapBehavior = SymbolTapBehavior.STAY,
    val symbolTapScope: SymbolTapScope = SymbolTapScope.NUMBERS_AND_SYMBOLS,
    val keyPreviewsEnabled: Boolean = true,
    val hapticsEnabled: Boolean = true,
    val doubleSpacePeriodEnabled: Boolean = true,
    val autocorrectionEnabled: Boolean = true,
    val swipeTypingEnabled: Boolean = true,
    val enhancedPunctuationEnabled: Boolean = true,
) {
    fun normalized() = copy(alternateHoldDelayMillis = alternateHoldDelayMillis.coerceIn(250, 1_200))
}

class ScribePreferences(context: Context) {
    private val store: SharedPreferences =
        context.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    var keyboard: KeyboardPreferences
        get() = KeyboardPreferences(
            alternateSymbolsEnabled = store.getBoolean(KEY_ALTERNATES, true),
            alternateHoldDelayMillis = store.getInt(KEY_HOLD_DELAY, 650),
            symbolTapBehavior = store.getString(KEY_SYMBOL_BEHAVIOR, null)
                ?.let { runCatching { SymbolTapBehavior.valueOf(it) }.getOrNull() }
                ?: SymbolTapBehavior.STAY,
            symbolTapScope = store.getString(KEY_SYMBOL_SCOPE, null)
                ?.let { runCatching { SymbolTapScope.valueOf(it) }.getOrNull() }
                ?: SymbolTapScope.NUMBERS_AND_SYMBOLS,
            keyPreviewsEnabled = store.getBoolean(KEY_PREVIEWS, true),
            hapticsEnabled = store.getBoolean(KEY_HAPTICS, true),
            doubleSpacePeriodEnabled = store.getBoolean(KEY_DOUBLE_SPACE, true),
            autocorrectionEnabled = store.getBoolean(KEY_AUTOCORRECTION, true),
            swipeTypingEnabled = store.getBoolean(KEY_SWIPE, true),
            enhancedPunctuationEnabled = store.getBoolean(KEY_ENHANCED_PUNCTUATION, true),
        ).normalized()
        set(value) {
            val normalized = value.normalized()
            store.edit()
                .putBoolean(KEY_ALTERNATES, normalized.alternateSymbolsEnabled)
                .putInt(KEY_HOLD_DELAY, normalized.alternateHoldDelayMillis)
                .putString(KEY_SYMBOL_BEHAVIOR, normalized.symbolTapBehavior.name)
                .putString(KEY_SYMBOL_SCOPE, normalized.symbolTapScope.name)
                .putBoolean(KEY_PREVIEWS, normalized.keyPreviewsEnabled)
                .putBoolean(KEY_HAPTICS, normalized.hapticsEnabled)
                .putBoolean(KEY_DOUBLE_SPACE, normalized.doubleSpacePeriodEnabled)
                .putBoolean(KEY_AUTOCORRECTION, normalized.autocorrectionEnabled)
                .putBoolean(KEY_SWIPE, normalized.swipeTypingEnabled)
                .putBoolean(KEY_ENHANCED_PUNCTUATION, normalized.enhancedPunctuationEnabled)
                .apply()
        }

    fun resetKeyboard() {
        keyboard = KeyboardPreferences()
    }

    companion object {
        private const val FILE_NAME = "scribe.preferences"
        private const val KEY_ALTERNATES = "keyboard.alternateSymbols"
        private const val KEY_HOLD_DELAY = "keyboard.alternateHoldDelay"
        private const val KEY_SYMBOL_BEHAVIOR = "keyboard.symbolTapBehavior"
        private const val KEY_SYMBOL_SCOPE = "keyboard.symbolTapScope"
        private const val KEY_PREVIEWS = "keyboard.keyPreviews"
        private const val KEY_HAPTICS = "keyboard.haptics"
        private const val KEY_DOUBLE_SPACE = "keyboard.doubleSpacePeriod"
        private const val KEY_AUTOCORRECTION = "keyboard.autocorrection"
        private const val KEY_SWIPE = "keyboard.swipeTyping"
        private const val KEY_ENHANCED_PUNCTUATION = "dictation.enhancedPunctuation"
    }
}
