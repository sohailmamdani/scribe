package com.sohail.scribe.keyboard

import android.content.Context
import com.sohail.scribe.core.KeyboardEditingRules
import kotlin.math.hypot
import kotlin.math.log10
import kotlin.math.min

data class CorrectionCandidate(
    val text: String,
    val automaticallyReplaces: Boolean,
    val isCompletion: Boolean = false,
)

class KeyboardLexicon(context: Context) {
    private data class Entry(val word: String, val frequency: Long, val letterMask: Int)
    private data class BigramTable(val keys: LongArray, val logFrequencies: FloatArray)

    private val entries: List<Entry> = context.assets.open("AutocorrectWords.txt").bufferedReader().useLines { lines ->
        lines.mapNotNull { line ->
            val separator = line.indexOf(' ')
            val word = line.substring(0, separator.takeIf { it > 0 } ?: line.length).trim().lowercase()
            val frequency = if (separator > 0) line.substring(separator + 1).trim().toLongOrNull() ?: 1L else 1L
            word.takeIf { it.length >= 2 && it.all { char -> char.isLetter() || char == '\'' } }
                ?.let { Entry(it, frequency, letterMask(it)) }
        }.toList()
    }
    private val exactWords = entries.mapTo(HashSet(entries.size)) { it.word }
    private val entriesByBucket = entries.groupBy { it.word.length to it.word.first() }
    private val wordIndex = entries.mapIndexed { index, entry -> entry.word to index }.toMap()
    private val bigrams = loadBigrams(context)

    fun corrections(
        original: String,
        contextBefore: CharSequence? = null,
        protectedWords: Set<String> = emptySet(),
        acceptedCounts: Map<String, Int> = emptyMap(),
        evidence: List<KeyboardTapEvidence?> = emptyList(),
        limit: Int = 3,
    ): List<CorrectionCandidate> {
        val source = original.lowercase()
        if (source.length < 2) return emptyList()
        val protected = source in protectedWords
        val preferredContraction = KeyboardEditingRules.preferredContraction(source)
            ?.takeIf { !protected }
            ?.let { contraction ->
                CorrectionCandidate(
                    matchCapitalization(contraction, original),
                    automaticallyReplaces = true,
                )
            }
        val maximumDistance = when {
            source.length >= 8 -> 3
            source.length >= 4 -> 2
            else -> 1
        }
        val completions = if (source.length >= 3) {
            entries.asSequence()
                .filter { it.word.length > source.length && it.word.startsWith(source) }
                .take(limit)
                .map { CorrectionCandidate(matchCapitalization(it.word, original), false, true) }
                .toList()
        } else {
            emptyList()
        }
        if (source in exactWords) {
            return (listOfNotNull(preferredContraction) + completions)
                .distinctBy { it.text.lowercase() }
                .take(limit)
        }

        val previousWord = KeyboardEditingRules.previousWord(contextBefore)?.lowercase()
        val sourceMask = letterMask(source)
        val possibleFirstLetters = firstLetterNeighbors(source.first())

        val ranked = ((source.length - maximumDistance).coerceAtLeast(1)..(source.length + maximumDistance))
            .asSequence()
            .flatMap { length ->
                possibleFirstLetters.asSequence().flatMap { first ->
                    entriesByBucket[length to first].orEmpty().asSequence()
                }
            }
            .filter { entry ->
                val missingFromCandidate = Integer.bitCount(sourceMask and entry.letterMask.inv())
                val missingFromSource = Integer.bitCount(entry.letterMask and sourceMask.inv())
                maxOf(missingFromCandidate, missingFromSource) <= maximumDistance
            }
            .mapNotNull { entry ->
                val distance = correctionDistance(source, entry.word)
                if (distance > maximumDistance) null
                else RankedCorrectionCandidate(
                    word = entry.word,
                    distance = distance,
                    frequency = entry.frequency,
                    bigramLogFrequency = previousWord?.let { bigramLogFrequency(it, entry.word) } ?: 0.0,
                    spatialCost = KeyboardCorrectionRanking.spatialCost(source, entry.word, evidence),
                    acceptedCount = acceptedCounts[
                        KeyboardCorrectionRanking.pairKey(source, entry.word)
                    ] ?: 0,
                    changesFirstLetter = source.firstOrNull() != entry.word.firstOrNull(),
                )
            }
            .toList()
            .let(KeyboardCorrectionRanking::rank)
        val automaticallyReplaces = KeyboardCorrectionRanking.shouldAutomaticallyReplace(
            original = source,
            originalIsKnownWord = false,
            protected = protected,
            ranked = ranked,
        )
        var corrections = if (protected) {
            emptyList()
        } else {
            ranked.take(limit).mapIndexed { index, candidate ->
                CorrectionCandidate(
                    text = matchCapitalization(candidate.word, original),
                    automaticallyReplaces = index == 0 && automaticallyReplaces,
                )
            }
        }
        preferredContraction?.let { contraction ->
            corrections = listOf(contraction) + corrections.filterNot {
                it.text.equals(contraction.text, ignoreCase = true)
            }
        }
        return (corrections + completions).distinctBy { it.text.lowercase() }.take(limit)
    }

    private fun loadBigrams(context: Context): BigramTable {
        val pairs = ArrayList<Pair<Long, Float>>(wordIndex.size * 8)
        context.assets.open("AutocorrectBigrams.txt").bufferedReader().useLines { lines ->
            var cachedFirstWord: String? = null
            var cachedFirstIndex: Int? = null
            lines.forEach { line ->
                val firstSpace = line.indexOf(' ')
                val secondSpace = line.indexOf(' ', firstSpace + 1)
                if (firstSpace <= 0 || secondSpace <= firstSpace + 1) return@forEach
                val firstWord = line.substring(0, firstSpace)
                if (firstWord != cachedFirstWord) {
                    cachedFirstWord = firstWord
                    cachedFirstIndex = wordIndex[firstWord]
                }
                val first = cachedFirstIndex ?: return@forEach
                val second = wordIndex[line.substring(firstSpace + 1, secondSpace)] ?: return@forEach
                val frequency = line.substring(secondSpace + 1).toLongOrNull() ?: return@forEach
                val key = (first.toLong() shl 32) or (second.toLong() and 0xffff_ffffL)
                pairs += key to log10(frequency.coerceAtLeast(0).toDouble() + 1.0).toFloat()
            }
        }
        pairs.sortBy { it.first }
        return BigramTable(
            keys = LongArray(pairs.size) { pairs[it].first },
            logFrequencies = FloatArray(pairs.size) { pairs[it].second },
        )
    }

    private fun bigramLogFrequency(first: String, second: String): Double {
        val firstIndex = wordIndex[first] ?: return 0.0
        val secondIndex = wordIndex[second] ?: return 0.0
        val key = (firstIndex.toLong() shl 32) or (secondIndex.toLong() and 0xffff_ffffL)
        val found = bigrams.keys.binarySearch(key)
        return if (found >= 0) bigrams.logFrequencies[found].toDouble() else 0.0
    }

    companion object {
        private val qwertyRows = listOf("qwertyuiop", "asdfghjkl", "zxcvbnm")

        private fun firstLetterNeighbors(character: Char): Set<Char> {
            val result = mutableSetOf(character)
            qwertyRows.forEachIndexed { rowIndex, row ->
                val column = row.indexOf(character)
                if (column < 0) return@forEachIndexed
                for (candidateRowIndex in (rowIndex - 1).coerceAtLeast(0)..minOf(rowIndex + 1, qwertyRows.lastIndex)) {
                    val candidateRow = qwertyRows[candidateRowIndex]
                    for (candidateColumn in (column - 1).coerceAtLeast(0)..minOf(column + 1, candidateRow.lastIndex)) {
                        result += candidateRow[candidateColumn]
                    }
                }
            }
            return result
        }

        private fun letterMask(word: String): Int {
            var mask = 0
            word.forEach { character ->
                if (character in 'a'..'z') mask = mask or (1 shl (character - 'a'))
            }
            return mask
        }

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

class SwipeWordDecoder private constructor(words: List<String>) {
    private data class Point(val x: Double, val y: Double)
    private data class Entry(
        val word: String,
        val letters: String,
        val rank: Int,
        val path: List<Point>,
    )

    constructor(context: Context) : this(
        context.assets.open("SwipeWords.txt").bufferedReader().useLines { lines ->
            lines.map(String::trim).toList()
        },
    )

    private val entriesByFirst: Map<Char, List<Entry>> = buildMap<Char, MutableList<Entry>> {
        var rank = 0
        words.forEach { raw ->
            val word = raw.lowercase()
            if (word.length < 2 || !word.all { it in 'a'..'z' }) return@forEach
            val path = word.mapNotNull(KEY_POSITIONS::get).fold(mutableListOf<Point>()) { points, point ->
                if (points.lastOrNull() != point) points += point
                points
            }
            if (path.isEmpty()) return@forEach
            rank += 1
            getOrPut(word.first()) { mutableListOf() } += Entry(word, word, rank, path)
        }
    }

    fun decode(keys: List<Char>): String? {
        if (keys.size < 2) return null
        val normalizedKeys = keys.map(Char::lowercaseChar)
        val firstKey = normalizedKeys.first()
        val lastKey = normalizedKeys.last()
        val swipePath = resample(normalizedKeys.mapNotNull(KEY_POSITIONS::get))
        if (swipePath.isEmpty()) return null

        val firstLetters = KEY_POSITIONS.keys.filterTo(mutableSetOf(firstKey)) {
            areNeighbors(firstKey, it)
        }
        var best: Pair<String, Double>? = null
        firstLetters.forEach { firstLetter ->
            entriesByFirst[firstLetter].orEmpty().forEach { entry ->
                val lastLetter = entry.letters.last()
                if (lastLetter != lastKey && !areNeighbors(lastLetter, lastKey)) return@forEach
                val idealPath = resample(entry.path)
                val shapeDistance = meanDistance(swipePath, idealPath)
                if (shapeDistance >= MAXIMUM_SHAPE_DISTANCE) return@forEach

                val startDistance = distance(swipePath.first(), idealPath.first())
                val endDistance = distance(swipePath.last(), idealPath.last())
                var score = -shapeDistance * 2.5
                score -= (startDistance + endDistance) * 1.2
                score += 3.0 * (1.0 - log10(entry.rank.toDouble() + 1.0) / 4.5)
                if (best == null || score > best!!.second) best = entry.word to score
            }
        }
        return best?.first
    }

    companion object {
        private const val SAMPLE_COUNT = 32
        private const val MAXIMUM_SHAPE_DISTANCE = 1.8
        private val KEY_POSITIONS: Map<Char, Point> = buildMap {
            listOf("qwertyuiop", "asdfghjkl", "zxcvbnm").forEachIndexed { rowIndex, row ->
                val rowOffset = listOf(0.0, 0.5, 1.5)[rowIndex]
                row.forEachIndexed { column, character ->
                    put(character, Point(column + rowOffset, rowIndex.toDouble()))
                }
            }
        }

        internal fun forWords(words: List<String>) = SwipeWordDecoder(words)

        internal fun areNeighbors(first: Char, second: Char): Boolean {
            val a = KEY_POSITIONS[first.lowercaseChar()] ?: return false
            val b = KEY_POSITIONS[second.lowercaseChar()] ?: return false
            val dx = a.x - b.x
            val dy = a.y - b.y
            return dx * dx + dy * dy <= 2.25
        }

        private fun resample(points: List<Point>): List<Point> {
            val first = points.firstOrNull() ?: return emptyList()
            if (points.size == 1) return List(SAMPLE_COUNT) { first }
            val cumulative = MutableList(points.size) { 0.0 }
            for (index in 1 until points.size) {
                cumulative[index] = cumulative[index - 1] + distance(points[index], points[index - 1])
            }
            val total = cumulative.last()
            if (total <= 0.0) return List(SAMPLE_COUNT) { first }

            var segment = 1
            return List(SAMPLE_COUNT) { sample ->
                val target = total * sample / (SAMPLE_COUNT - 1).toDouble()
                while (segment < points.lastIndex && cumulative[segment] < target) segment += 1
                val segmentLength = (cumulative[segment] - cumulative[segment - 1]).coerceAtLeast(0.0001)
                val fraction = (target - cumulative[segment - 1]) / segmentLength
                val start = points[segment - 1]
                val end = points[segment]
                Point(
                    start.x + (end.x - start.x) * fraction,
                    start.y + (end.y - start.y) * fraction,
                )
            }
        }

        private fun meanDistance(first: List<Point>, second: List<Point>): Double =
            (0 until SAMPLE_COUNT).sumOf { distance(first[it], second[it]) } / SAMPLE_COUNT

        private fun distance(first: Point, second: Point): Double =
            hypot(first.x - second.x, first.y - second.y)
    }
}
