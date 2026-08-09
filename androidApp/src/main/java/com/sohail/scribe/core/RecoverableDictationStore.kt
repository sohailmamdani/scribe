package com.sohail.scribe.core

import android.content.Context

/**
 * Keeps one finished-but-not-inserted dictation private until the user chooses
 * to insert or discard it. The short lifetime mirrors the iOS handoff window
 * and prevents an abandoned transcript from following the user indefinitely.
 */
internal class RecoverableDictationStore(
    context: Context,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private val preferences = context.applicationContext
        .getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    @Synchronized
    fun save(text: String) {
        val cleaned = text.trim()
        if (cleaned.isEmpty()) {
            discard()
            return
        }
        preferences.edit()
            .putString(KEY_TEXT, cleaned)
            .putLong(KEY_CREATED_AT, nowMillis())
            .apply()
    }

    @Synchronized
    fun load(): String? {
        val text = preferences.getString(KEY_TEXT, null)?.trim().orEmpty()
        val createdAt = preferences.getLong(KEY_CREATED_AT, Long.MIN_VALUE)
        val age = nowMillis() - createdAt
        if (text.isEmpty() || age !in 0..MAX_AGE_MILLIS) {
            discard()
            return null
        }
        return text
    }

    @Synchronized
    fun consume(): String? = load().also { if (it != null) discard() }

    @Synchronized
    fun discard() {
        preferences.edit().remove(KEY_TEXT).remove(KEY_CREATED_AT).apply()
    }

    private companion object {
        const val FILE_NAME = "scribe.recoverable.dictation"
        const val KEY_TEXT = "text"
        const val KEY_CREATED_AT = "createdAtMillis"
        const val MAX_AGE_MILLIS = 15 * 60 * 1_000L
    }
}
