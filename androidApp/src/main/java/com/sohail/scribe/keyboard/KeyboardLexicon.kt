package com.sohail.scribe.keyboard

import android.content.Context
import kotlin.math.abs
import kotlin.math.min

data class CorrectionCandidate(
    val text: String,
    val automaticallyReplaces: Boolean,
    val isCompletion: Boolean = false,
)

class KeyboardLexicon(context: Context) {
    private data class Entry(val word: String, val rank: Int)

    private val entries: List<Entry> = context.assets.open("AutocorrectWords.txt").bufferedReader().useLines { lines ->
        lines.mapIndexedNotNull { index, line ->
            val word = line.substringBefore(' ').trim().lowercase()
            word.takeIf { it.length >= 2 && it.all { char -> char.isLetter() || char == '\'' } }
                ?.let { Entry(it, index) }
        }.toList()
    }
    private val exactWords = entries.mapTo(HashSet(entries.size)) { it.word }
    private val entriesByLength = entries.groupBy { it.word.length }

    fun corrections(original: String, limit: Int = 3): List<CorrectionCandidate> {
        val source = original.lowercase()
        if (source.length < 2) return emptyList()
        val maximumDistance = when {
            source.length >= 8 -> 3
            source.length >= 4 -> 2
            else -> 1
        }
        val completions = if (source.length >= 2) {
            entries.asSequence()
                .filter { it.word.length > source.length && it.word.startsWith(source) }
                .take(limit)
                .map { CorrectionCandidate(matchCapitalization(it.word, original), false, true) }
                .toList()
        } else {
            emptyList()
        }
        if (source in exactWords) return completions

        val corrections = ((source.length - maximumDistance)..(source.length + maximumDistance))
            .asSequence()
            .flatMap { length -> entriesByLength[length].orEmpty().asSequence() }
            .mapNotNull { entry ->
                val distance = correctionDistance(source, entry.word)
                if (distance > maximumDistance) null
                else Triple(entry, distance, distance * 100_000 + entry.rank)
            }
            .sortedBy { it.third }
            .take(limit)
            .map { (entry, distance) ->
                CorrectionCandidate(
                    text = matchCapitalization(entry.word, original),
                    automaticallyReplaces = source.length >= 3 && distance == 1,
                )
            }
            .toList()
        return (corrections + completions).distinctBy { it.text.lowercase() }.take(limit)
    }

    companion object {
        fun matchCapitalization(suggestion: String, original: String): String = when {
            suggestion.startsWith("i'") -> "I" + suggestion.drop(1)
            original.firstOrNull()?.isUpperCase() == true && original.drop(1) == original.drop(1).lowercase() ->
                suggestion.replaceFirstChar(Char::uppercase)
            else -> suggestion
        }

        fun correctionDistance(source: String, destination: String): Int {
            if (source.isEmpty()) return destination.length
            if (destination.isEmpty()) return source.length
            val rows = Array(source.length + 1) { IntArray(destination.length + 1) }
            for (left in 0..source.length) rows[left][0] = left
            for (right in 0..destination.length) rows[0][right] = right
            for (left in 1..source.length) {
                for (right in 1..destination.length) {
                    val substitution = if (source[left - 1] == destination[right - 1]) 0 else 1
                    rows[left][right] = min(
                        min(rows[left - 1][right] + 1, rows[left][right - 1] + 1),
                        rows[left - 1][right - 1] + substitution,
                    )
                    if (
                        left > 1 && right > 1 &&
                        source[left - 1] == destination[right - 2] &&
                        source[left - 2] == destination[right - 1]
                    ) {
                        rows[left][right] = min(rows[left][right], rows[left - 2][right - 2] + 1)
                    }
                }
            }
            return rows[source.length][destination.length]
        }
    }
}

class SwipeWordDecoder(context: Context) {
    private data class Entry(val word: String, val path: String, val rank: Int)

    private val entriesByFirst = context.assets.open("SwipeWords.txt").bufferedReader().useLines { lines ->
        lines.mapIndexedNotNull { index, raw ->
            val word = raw.trim().lowercase()
            word.takeIf { it.length >= 2 && it.all(Char::isLetter) }
                ?.let { Entry(word, collapse(it), index) }
        }.toList().groupBy { it.path.first() }
    }

    fun decode(keys: List<Char>): String? {
        val path = collapse(keys.joinToString("").lowercase())
        if (path.length < 2) return null
        return entriesByFirst[path.first()].orEmpty()
            .asSequence()
            .filter { it.path.last() == path.last() }
            .filter { abs(it.path.length - path.length) <= 4 }
            .map { entry ->
                val distance = KeyboardLexicon.correctionDistance(path, entry.path)
                entry to (distance * 10_000 + entry.rank)
            }
            .filter { (entry, score) -> score / 10_000 <= maxOf(2, entry.path.length / 3) }
            .minByOrNull { it.second }
            ?.first
            ?.word
    }

    companion object {
        private fun collapse(text: String): String = buildString {
            text.forEach { if (lastOrNull() != it) append(it) }
        }
    }
}
