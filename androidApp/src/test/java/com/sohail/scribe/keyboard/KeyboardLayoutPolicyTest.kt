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
        assertEquals(313f, KeyboardLayoutPolicy.portraitGeometry.contentHeightDp)
        assertEquals(301f, KeyboardLayoutPolicy.landscapeGeometry.contentHeightDp)
        assertTrue(KeyboardLayoutPolicy.portraitGeometry.keyHeightDp < 50f)
    }

    @Test fun splitGapTracksWidthWithinErgonomicBounds() {
        assertEquals(252f, KeyboardLayoutPolicy.splitGapDp(600f), 0.01f)
        assertEquals(537.6f, KeyboardLayoutPolicy.splitGapDp(1_280f), 0.01f)
        assertEquals(168f, KeyboardLayoutPolicy.splitGapDp(400f), 0.01f)
        assertEquals(53.76f, KeyboardLayoutPolicy.splitOuterInsetDp(1_280f), 0.01f)
    }
}
