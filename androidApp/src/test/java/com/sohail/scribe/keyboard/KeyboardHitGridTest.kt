package com.sohail.scribe.keyboard

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class KeyboardHitGridTest {
    @Test fun regionsTileHorizontalAndVerticalGaps() {
        val regions = KeyboardHitGrid.regions(
            frames = mapOf(
                "q" to rect(10, 10, 40, 50),
                "w" to rect(46, 10, 76, 50),
                "a" to rect(24, 58, 54, 98),
            ),
            bounds = rect(0, 0, 100, 108),
        )

        assertEquals("q", KeyboardHitGrid.keyAt(42f, 30f, regions, 0f))
        assertEquals("w", KeyboardHitGrid.keyAt(44f, 30f, regions, 0f))
        assertEquals("q", KeyboardHitGrid.keyAt(15f, 53f, regions, 0f))
        assertEquals("a", KeyboardHitGrid.keyAt(40f, 55f, regions, 0f))
        assertEquals("q", KeyboardHitGrid.keyAt(0f, 0f, regions, 0f))
        assertEquals("w", KeyboardHitGrid.keyAt(100f, 0f, regions, 0f))
        assertEquals("a", KeyboardHitGrid.keyAt(100f, 108f, regions, 0f))
    }

    @Test fun verticalBiasLiftsAimingPointTowardKeyAbove() {
        val regions = KeyboardHitGrid.regions(
            frames = mapOf(
                "q" to rect(0, 0, 40, 40),
                "a" to rect(0, 48, 40, 88),
            ),
            bounds = rect(0, 0, 40, 88),
        )

        assertEquals("a", KeyboardHitGrid.keyAt(20f, 45f, regions, 0f))
        assertEquals("q", KeyboardHitGrid.keyAt(20f, 45f, regions, 2f))
    }

    @Test fun distantTouchesDoNotResolveBackIntoKeyboard() {
        val regions = KeyboardHitGrid.regions(
            frames = mapOf("q" to rect(0, 0, 40, 40)),
            bounds = rect(0, 0, 40, 40),
        )

        assertEquals("q", KeyboardHitGrid.keyAt(50f, 20f, regions, 0f))
        assertNull(KeyboardHitGrid.keyAt(100f, 20f, regions, 0f))
    }

    @Test fun generatedRegionsHaveNoAreaGapsAcrossPhoneAndTabletWidths() {
        listOf(320, 440, 800, 1_280).forEach { width ->
            val gap = 6f
            val capWidth = (width - 20f - gap * 9f) / 10f
            val frames = (0 until 10).associate { index ->
                "key-$index" to KeyboardHitRect(
                    10f + index * (capWidth + gap),
                    10f,
                    10f + index * (capWidth + gap) + capWidth,
                    55f,
                )
            }
            val regions = KeyboardHitGrid.regions(
                frames,
                KeyboardHitRect(0f, 0f, width.toFloat(), 65f),
            )
            assertEquals(10, regions.size)
            (0..width).forEach { x ->
                assertTrue(
                    KeyboardHitGrid.keyAt(x.toFloat(), 30f, regions, 0f) != null,
                    "dead zone at width=$width x=$x",
                )
            }
        }
    }

    private fun rect(left: Int, top: Int, right: Int, bottom: Int) =
        KeyboardHitRect(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat())
}
