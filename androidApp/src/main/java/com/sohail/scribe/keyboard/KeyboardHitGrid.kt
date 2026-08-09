package com.sohail.scribe.keyboard

import kotlin.math.hypot

/** A platform-neutral rectangle so the IME hit geometry is JVM-testable. */
data class KeyboardHitRect(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
) {
    val centerX: Float get() = (left + right) / 2f
    val centerY: Float get() = (top + bottom) / 2f

    fun contains(x: Float, y: Float): Boolean =
        x >= left && x <= right && y >= top && y <= bottom
}

/**
 * Converts visual keycaps into a gap-free touch grid.
 *
 * The visible caps keep native spacing, while the touch regions meet halfway
 * across every gap and extend to the keyboard edges. This mirrors the iOS
 * keyboard contract: a tap between caps resolves deterministically instead of
 * disappearing, and wide control keys are ranked by their boundary rather
 * than by a distant centre point.
 */
object KeyboardHitGrid {
    const val PORTRAIT_VERTICAL_TAP_BIAS = 2f
    const val COMPACT_VERTICAL_TAP_BIAS = 1f
    const val MAXIMUM_OUTSIDE_DISTANCE = 44f

    fun regions(
        frames: Map<String, KeyboardHitRect>,
        bounds: KeyboardHitRect,
    ): Map<String, KeyboardHitRect> {
        if (frames.isEmpty()) return emptyMap()
        val rows = rowGroups(frames)
        if (rows.isEmpty()) return emptyMap()

        return buildMap {
            rows.forEachIndexed { rowIndex, row ->
                val rowMinY = row.minOf { it.second.top }
                val rowMaxY = row.maxOf { it.second.bottom }
                val top = if (rowIndex == 0) {
                    minOf(bounds.top, rowMinY)
                } else {
                    (rows[rowIndex - 1].maxOf { it.second.bottom } + rowMinY) / 2f
                }
                val bottom = if (rowIndex == rows.lastIndex) {
                    maxOf(bounds.bottom, rowMaxY)
                } else {
                    (rowMaxY + rows[rowIndex + 1].minOf { it.second.top }) / 2f
                }

                row.forEachIndexed { index, entry ->
                    val left = if (index == 0) {
                        minOf(bounds.left, entry.second.left)
                    } else {
                        (row[index - 1].second.right + entry.second.left) / 2f
                    }
                    val right = if (index == row.lastIndex) {
                        maxOf(bounds.right, entry.second.right)
                    } else {
                        (entry.second.right + row[index + 1].second.left) / 2f
                    }
                    put(entry.first, KeyboardHitRect(left, top, right, bottom))
                }
            }
        }
    }

    fun keyAt(
        x: Float,
        y: Float,
        regions: Map<String, KeyboardHitRect>,
        verticalTapBias: Float,
        maximumOutsideDistance: Float = MAXIMUM_OUTSIDE_DISTANCE,
    ): String? {
        if (regions.isEmpty()) return null
        val adjustedY = y - verticalTapBias
        val containing = regions.entries
            .filter { it.value.contains(x, adjustedY) }
            .minByOrNull { distance(it.value, x, adjustedY) }
        if (containing != null) return containing.key

        val nearest = regions.entries.minByOrNull { distance(it.value, x, adjustedY) } ?: return null
        return nearest.key.takeIf {
            distance(nearest.value, x, adjustedY) <= maximumOutsideDistance
        }
    }

    fun distance(rect: KeyboardHitRect, x: Float, y: Float): Float {
        val clampedX = x.coerceIn(rect.left, rect.right)
        val clampedY = y.coerceIn(rect.top, rect.bottom)
        return hypot(x - clampedX, y - clampedY)
    }

    private fun rowGroups(
        frames: Map<String, KeyboardHitRect>,
    ): List<List<Pair<String, KeyboardHitRect>>> {
        val sorted = frames.entries
            .map { it.key to it.value }
            .sortedWith(compareBy<Pair<String, KeyboardHitRect>> { it.second.centerY }
                .thenBy { it.second.centerX })
        val rows = mutableListOf<MutableList<Pair<String, KeyboardHitRect>>>()
        sorted.forEach { entry ->
            val reference = rows.lastOrNull()?.firstOrNull()?.second
            if (reference != null && entry.second.centerY < reference.bottom) {
                rows.last() += entry
            } else {
                rows += mutableListOf(entry)
            }
        }
        return rows.map { row -> row.sortedBy { it.second.centerX } }
    }
}
