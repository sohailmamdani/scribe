package com.sohail.scribe.keyboard

import kotlin.math.abs

object KeyboardGestureRules {
    /** Matches the bounded alternate-palette selection area used by iOS. */
    fun remainsInAlternateSelection(
        deltaX: Float,
        deltaY: Float,
        keyHeight: Float,
    ): Boolean = abs(deltaX) <= keyHeight &&
        deltaY >= -keyHeight / 2f &&
        deltaY <= keyHeight * 1.25f
}
