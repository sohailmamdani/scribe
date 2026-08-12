package com.sohail.scribe.keyboard

import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.sohail.scribe.core.KeyboardPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class KeyboardGeometryInstrumentationTest {
    @Test fun portraitUsesFixedGboardScaleInsteadOfStretchingKeys() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val context = instrumentation.targetContext
            val density = context.resources.displayMetrics.density
            val view = measuredView(
                view = ScribeKeyboardView(context),
                width = (412f * density).toInt(),
            )

            assertEquals(KeyboardLayoutMode.COMPACT, view.currentLayoutMode())
            val q = requireNotNull(view.visualKeyRects()["key-q"])
            assertTrue(abs(q.height() - 48f * density) < 1.5f)
            assertTrue(abs(view.measuredHeight - 272f * density) < 2f)
        }
    }

    @Test fun navigationAndGestureInsetAddsUntouchableClearanceBelowKeys() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val context = instrumentation.targetContext
            val density = context.resources.displayMetrics.density
            val systemInset = (28f * density).toInt()
            val view = ScribeKeyboardView(context)
            view.applySystemBottomInset(systemInset)
            measuredView(view, width = (412f * density).toInt())

            val space = requireNotNull(view.visualKeyRects()["space"])
            assertEquals(systemInset, view.systemBottomInsetForTesting())
            assertTrue(space.bottom <= view.height - systemInset - 7f * density)
            assertEquals(null, view.keyIdAtForTesting(space.centerX(), view.height - systemInset / 2f))
        }
    }

    @Test fun unfoldedWidthSplitsLettersAtTheCenterAndKeepsAContinuousSpacebar() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val context = instrumentation.targetContext
            val density = context.resources.displayMetrics.density
            val view = measuredView(
                view = ScribeKeyboardView(context),
                width = (841f * density).toInt(),
            )

            assertEquals(KeyboardLayoutMode.SPLIT, view.currentLayoutMode())
            val gap = requireNotNull(view.splitDeadZoneRect())
            val rects = view.visualKeyRects()
            assertTrue(gap.width() >= 88f * density)
            assertTrue(requireNotNull(rects["key-t-left"]).right <= gap.left)
            assertTrue(requireNotNull(rects["key-y-right"]).left >= gap.right)
            assertNotNull(rects["key-g-left"])
            assertNotNull(rects["key-g-right"])
            assertNotNull(rects["key-v-left"])
            assertNotNull(rects["key-v-right"])
            val leftG = requireNotNull(rects["key-g-left"])
            val leftGEvidence = view.tapEvidenceForTesting('g', leftG.centerX(), leftG.centerY())
            assertEquals(0.0, leftGEvidence.normalizedDistances['g'] ?: -1.0, 0.0001)
            val space = requireNotNull(rects["space"])
            assertTrue(space.left < gap.left && space.right > gap.right)
        }
    }

    @Test fun symbolsKeepTheSplitCenterGap() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val context = instrumentation.targetContext
            val density = context.resources.displayMetrics.density
            val view = measuredView(
                view = ScribeKeyboardView(context),
                width = (841f * density).toInt(),
            )
            val provider = view.accessibilityNodeProvider!!
            val mode = view.visibleAccessibilityVirtualIds().first { virtualId ->
                provider.createAccessibilityNodeInfo(virtualId)?.contentDescription?.toString() ==
                    "Numbers and symbols"
            }
            assertTrue(provider.performAction(mode, AccessibilityNodeInfo.ACTION_CLICK, null))

            val gap = requireNotNull(view.splitDeadZoneRect())
            val symbolCaps = view.visualKeyRects().filterKeys { it.startsWith("symbol-") }.values
            assertTrue(symbolCaps.isNotEmpty())
            assertTrue(symbolCaps.none { it.left < gap.right && it.right > gap.left })
        }
    }

    @Test fun wideScreenSplitPreferenceCanRestoreAJoinedLayout() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val context = instrumentation.targetContext
            val density = context.resources.displayMetrics.density
            val view = ScribeKeyboardView(context).apply {
                updatePreferences(KeyboardPreferences(splitWideLayoutsEnabled = false))
            }
            measuredView(view, width = (841f * density).toInt())

            assertEquals(KeyboardLayoutMode.COMPACT, view.currentLayoutMode())
            assertEquals(null, view.splitDeadZoneRect())
            assertNotNull(view.visualKeyRects()["key-q"])
        }
    }

    private fun measuredView(view: ScribeKeyboardView, width: Int): ScribeKeyboardView {
        view.measure(
            View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(4_000, View.MeasureSpec.AT_MOST),
        )
        view.layout(0, 0, width, view.measuredHeight)
        return view
    }
}
