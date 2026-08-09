package com.sohail.scribe.core

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

data class DictationHistoryItem(
    val id: String,
    val text: String,
    val createdAtMillis: Long,
)

class DictationHistoryStore(context: Context) {
    private val preferences = context.applicationContext
        .getSharedPreferences("scribe.history", Context.MODE_PRIVATE)

    @Synchronized
    fun load(): List<DictationHistoryItem> {
        val raw = preferences.getString(KEY_ITEMS, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.getJSONObject(index)
                    add(
                        DictationHistoryItem(
                            id = item.getString("id"),
                            text = item.getString("text"),
                            createdAtMillis = item.getLong("createdAtMillis"),
                        ),
                    )
                }
            }
        }.getOrDefault(emptyList())
    }

    @Synchronized
    fun add(text: String): DictationHistoryItem? {
        val cleaned = text.trim()
        if (cleaned.isEmpty()) return null
        val item = DictationHistoryItem(UUID.randomUUID().toString(), cleaned, System.currentTimeMillis())
        persist(listOf(item) + load().filterNot { it.text == cleaned }.take(MAX_ITEMS - 1))
        return item
    }

    @Synchronized
    fun clear() = preferences.edit().remove(KEY_ITEMS).apply()

    private fun persist(items: List<DictationHistoryItem>) {
        val array = JSONArray()
        items.take(MAX_ITEMS).forEach { item ->
            array.put(
                JSONObject()
                    .put("id", item.id)
                    .put("text", item.text)
                    .put("createdAtMillis", item.createdAtMillis),
            )
        }
        preferences.edit().putString(KEY_ITEMS, array.toString()).apply()
    }

    companion object {
        private const val KEY_ITEMS = "items"
        private const val MAX_ITEMS = 50
    }
}
