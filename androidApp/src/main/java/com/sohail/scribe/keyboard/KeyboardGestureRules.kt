package com.sohail.scribe.keyboard

import kotlin.math.abs

object KeyboardGestureRules {
    const val PREVIEW_DISTANCE = 12f
    const val SWIPE_DISTANCE = 24f

    fun shouldCancelAlternateHold(deltaX: Float, deltaY: Float): Boolean =
        kotlin.math.hypot(deltaX, deltaY) > PREVIEW_DISTANCE

    /** Matches the bounded alternate-palette selection area used by iOS. */
    fun remainsInAlternateSelection(
        deltaX: Float,
        deltaY: Float,
        keyHeight: Float,
    ): Boolean = abs(deltaX) <= keyHeight &&
        deltaY >= -keyHeight / 2f &&
        deltaY <= keyHeight * 1.25f
}
