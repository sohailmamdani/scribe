package com.sohail.scribe.keyboard

import com.sohail.scribe.core.KeyboardEditingRules
import kotlin.math.log10

data class KeyboardTapEvidence(
    val character: Char,
    val normalizedDistances: Map<Char, Double>,
)

data class RankedCorrectionCandidate(
    val word: String,
    val distance: Int,
    val frequency: Long,
    val bigramLogFrequency: Double = 0.0,
    val spatialCost: Double = KeyboardCorrectionRanking.NEUTRAL_SPATIAL_COST,
    val acceptedCount: Int = 0,
    val changesFirstLetter: Boolean = false,
)

object KeyboardCorrectionRanking {
    const val NEUTRAL_SPATIAL_COST = 1.0
    const val UNREACHABLE_SPATIAL_COST = 1.9
    const val AUTO_REPLACE_MARGIN = 18.0

    fun score(candidate: RankedCorrectionCandidate): Double {
        var score = candidate.distance * 60.0
        score += (candidate.spatialCost - NEUTRAL_SPATIAL_COST) * 34.0
        if (candidate.changesFirstLetter) score += 25.0
        score -= log10(candidate.frequency.coerceAtLeast(0).toDouble() + 1.0) * 20.0
        score -= candidate.bigramLogFrequency * 8.0
        score -= candidate.acceptedCount.coerceIn(0, 12) * 5.0
        return score
    }

    fun rank(candidates: List<RankedCorrectionCandidate>): List<RankedCorrectionCandidate> =
        candidates.sortedWith(
            compareBy<RankedCorrectionCandidate>(::score)
                .thenByDescending { it.frequency }
                .thenBy { it.word },
        )

    fun shouldAutomaticallyReplace(
        original: String,
        originalIsKnownWord: Boolean,
        protected: Boolean,
        ranked: List<RankedCorrectionCandidate>,
    ): Boolean {
        if (originalIsKnownWord || protected || original.length < 3) return false
        val best = ranked.firstOrNull() ?: return false
        if (best.distance != 1 || best.frequency <= 1L ||
            !KeyboardEditingRules.isSafeCorrectionWord(best.word)
        ) return false
        val margin = ranked.getOrNull(1)?.let { score(it) - score(best) } ?: Double.POSITIVE_INFINITY
        return margin >= AUTO_REPLACE_MARGIN
    }

    fun spatialCost(
        original: String,
        candidate: String,
        evidence: List<KeyboardTapEvidence?>,
    ): Double {
        if (original.length != candidate.length) return NEUTRAL_SPATIAL_COST
        var differences = 0
        var total = 0.0
        original.indices.forEach { index ->
            if (original[index] == candidate[index]) return@forEach
            differences += 1
            val tap = evidence.getOrNull(index)
            total += if (tap?.character == original[index]) {
                tap.normalizedDistances[candidate[index]] ?: UNREACHABLE_SPATIAL_COST
            } else {
                NEUTRAL_SPATIAL_COST
            }
        }
        return if (differences == 0) 0.0 else total / differences
    }

    fun pairKey(original: String, replacement: String): String =
        "${original.lowercase()}\t${replacement.lowercase()}"
}
