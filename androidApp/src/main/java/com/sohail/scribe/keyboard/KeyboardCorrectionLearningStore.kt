package com.sohail.scribe.keyboard

import android.content.Context

class KeyboardCorrectionLearningStore(context: Context) {
    private val store = context.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
    private val protectedWords = store.getString(KEY_PROTECTED, "")
        .orEmpty().lineSequence().filter(String::isNotBlank).toMutableList()
    private val acceptedCounts = store.getString(KEY_ACCEPTED, "")
        .orEmpty().lineSequence().mapNotNull { line ->
            val separator = line.lastIndexOf('=')
            if (separator <= 0) null else line.substring(0, separator) to
                (line.substring(separator + 1).toIntOrNull() ?: return@mapNotNull null)
        }.toMap().toMutableMap()

    @Synchronized fun protectedWordsSnapshot(): Set<String> = protectedWords.toSet()

    @Synchronized fun acceptedCountsSnapshot(): Map<String, Int> = acceptedCounts.toMap()

    @Synchronized fun recordAccepted(original: String, replacement: String) {
        val key = KeyboardCorrectionRanking.pairKey(original, replacement)
        acceptedCounts[key] = ((acceptedCounts[key] ?: 0) + 1).coerceAtMost(100)
        persistAccepted()
    }

    @Synchronized fun recordRejected(original: String, replacement: String) {
        val normalized = original.lowercase()
        protectedWords.remove(normalized)
        protectedWords += normalized
        if (protectedWords.size > MAX_PROTECTED_WORDS) {
            protectedWords.subList(0, protectedWords.size - MAX_PROTECTED_WORDS).clear()
        }
        acceptedCounts.remove(KeyboardCorrectionRanking.pairKey(original, replacement))
        store.edit()
            .putString(KEY_PROTECTED, protectedWords.joinToString("\n"))
            .apply()
        persistAccepted()
    }

    @Synchronized private fun persistAccepted() {
        store.edit().putString(
            KEY_ACCEPTED,
            acceptedCounts.entries.joinToString("\n") { "${it.key}=${it.value}" },
        ).apply()
    }

    private companion object {
        const val FILE_NAME = "scribe.autocorrection.learning"
        const val KEY_PROTECTED = "protectedWords"
        const val KEY_ACCEPTED = "acceptedPairs"
        const val MAX_PROTECTED_WORDS = 512
    }
}
