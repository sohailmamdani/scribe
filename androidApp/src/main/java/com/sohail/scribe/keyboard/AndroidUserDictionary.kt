package com.sohail.scribe.keyboard

import android.content.Context
import android.provider.UserDictionary
import java.util.Locale

internal data class AndroidUserDictionaryRow(
    val word: String?,
    val shortcut: String?,
    val frequency: Int,
    val locale: String?,
)

internal data class AndroidUserDictionarySnapshot(
    val protectedWords: Set<String> = emptySet(),
    val candidateFrequencies: Map<String, Long> = emptyMap(),
)

internal object AndroidUserDictionaryPolicy {
    private const val USER_WORD_FREQUENCY_BASE = 20_000_000L

    fun snapshot(
        rows: Iterable<AndroidUserDictionaryRow>,
        activeLocale: Locale,
    ): AndroidUserDictionarySnapshot {
        val protectedWords = linkedSetOf<String>()
        val candidateFrequencies = linkedMapOf<String, Long>()
        rows.asSequence()
            .filter { localeMatches(it.locale, activeLocale) }
            .forEach { row ->
                listOf(row.word, row.shortcut).forEach valueLoop@{ rawValue ->
                    val value = rawValue?.trim()?.lowercase(activeLocale).orEmpty()
                    if (value.isEmpty()) return@valueLoop
                    protectedWords += value
                    if (value.length >= 2 && value.all { it.isLetter() || it == '\'' }) {
                        val frequency = USER_WORD_FREQUENCY_BASE + row.frequency.coerceIn(0, 255)
                        candidateFrequencies[value] = maxOf(candidateFrequencies[value] ?: 0L, frequency)
                    }
                }
            }
        return AndroidUserDictionarySnapshot(protectedWords, candidateFrequencies)
    }

    private fun localeMatches(rawLocale: String?, activeLocale: Locale): Boolean {
        val value = rawLocale?.trim().orEmpty()
        if (value.isEmpty()) return true
        val entryLocale = Locale.forLanguageTag(value.replace('_', '-'))
        val entryLanguage = entryLocale.language
        return entryLanguage.isNotEmpty() && entryLanguage.equals(activeLocale.language, ignoreCase = true)
    }
}

internal class AndroidUserDictionary(context: Context) {
    private val resolver = context.applicationContext.contentResolver

    fun snapshot(activeLocale: Locale): AndroidUserDictionarySnapshot = runCatching {
        val rows = buildList {
            resolver.query(
                UserDictionary.Words.CONTENT_URI,
                arrayOf(
                    UserDictionary.Words.WORD,
                    UserDictionary.Words.SHORTCUT,
                    UserDictionary.Words.FREQUENCY,
                    UserDictionary.Words.LOCALE,
                ),
                null,
                null,
                UserDictionary.Words.DEFAULT_SORT_ORDER,
            )?.use { cursor ->
                val wordIndex = cursor.getColumnIndex(UserDictionary.Words.WORD)
                val shortcutIndex = cursor.getColumnIndex(UserDictionary.Words.SHORTCUT)
                val frequencyIndex = cursor.getColumnIndex(UserDictionary.Words.FREQUENCY)
                val localeIndex = cursor.getColumnIndex(UserDictionary.Words.LOCALE)
                while (cursor.moveToNext()) {
                    add(
                        AndroidUserDictionaryRow(
                            word = cursor.stringOrNull(wordIndex),
                            shortcut = cursor.stringOrNull(shortcutIndex),
                            frequency = cursor.intOrZero(frequencyIndex),
                            locale = cursor.stringOrNull(localeIndex),
                        ),
                    )
                }
            }
        }
        AndroidUserDictionaryPolicy.snapshot(rows, activeLocale)
    }.getOrDefault(AndroidUserDictionarySnapshot())

    private fun android.database.Cursor.stringOrNull(column: Int): String? =
        column.takeIf { it >= 0 && !isNull(it) }?.let(::getString)

    private fun android.database.Cursor.intOrZero(column: Int): Int =
        column.takeIf { it >= 0 && !isNull(it) }?.let(::getInt) ?: 0
}
