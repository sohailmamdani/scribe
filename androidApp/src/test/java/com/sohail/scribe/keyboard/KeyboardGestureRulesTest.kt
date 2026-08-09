package com.sohail.scribe.keyboard

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class KeyboardGestureRulesTest {
    @Test fun alternatePaletteAllowsDeliberateNearbyMovement() {
        assertTrue(KeyboardGestureRules.remainsInAlternateSelection(0f, 0f, 45f))
        assertTrue(KeyboardGestureRules.remainsInAlternateSelection(20f, 40f, 45f))
        assertTrue(KeyboardGestureRules.remainsInAlternateSelection(-45f, -22f, 45f))
    }

    @Test fun alternatePaletteCancelsWhenFingerLeavesSelectionArea() {
        assertFalse(KeyboardGestureRules.remainsInAlternateSelection(46f, 0f, 45f))
        assertFalse(KeyboardGestureRules.remainsInAlternateSelection(0f, -23f, 45f))
        assertFalse(KeyboardGestureRules.remainsInAlternateSelection(0f, 57f, 45f))
    }
}
