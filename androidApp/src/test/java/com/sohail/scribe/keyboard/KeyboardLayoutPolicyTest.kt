package com.sohail.scribe.keyboard

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class KeyboardLayoutPolicyTest {
    @Test fun phonePortraitAndLandscapeRemainCompact() {
        assertEquals(
            KeyboardLayoutMode.COMPACT,
            KeyboardLayoutPolicy.layoutMode(412, 915, splitWideLayoutsEnabled = true),
        )
        assertEquals(
            KeyboardLayoutMode.COMPACT,
            KeyboardLayoutPolicy.layoutMode(915, 412, splitWideLayoutsEnabled = true),
        )
    }

    @Test fun unfoldedFoldablesAndTabletsUseSplitModeByDefault() {
        assertEquals(
            KeyboardLayoutMode.SPLIT,
            KeyboardLayoutPolicy.layoutMode(673, 841, splitWideLayoutsEnabled = true),
        )
        assertEquals(
            KeyboardLayoutMode.SPLIT,
            KeyboardLayoutPolicy.layoutMode(1_280, 800, splitWideLayoutsEnabled = true),
        )
    }

    @Test fun splitModeCanBeDisabled() {
        assertEquals(
            KeyboardLayoutMode.COMPACT,
            KeyboardLayoutPolicy.layoutMode(841, 701, splitWideLayoutsEnabled = false),
        )
    }

    @Test fun fixedGeometryDoesNotStretchWithWindowHeight() {
        assertEquals(272f, KeyboardLayoutPolicy.portraitGeometry.contentHeightDp)
        assertEquals(238f, KeyboardLayoutPolicy.landscapeGeometry.contentHeightDp)
        assertTrue(KeyboardLayoutPolicy.portraitGeometry.keyHeightDp < 50f)
    }

    @Test fun splitGapTracksWidthWithinErgonomicBounds() {
        assertEquals(102f, KeyboardLayoutPolicy.splitGapDp(600f))
        assertEquals(180f, KeyboardLayoutPolicy.splitGapDp(1_280f))
        assertEquals(88f, KeyboardLayoutPolicy.splitGapDp(400f))
    }
}
