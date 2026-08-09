package com.sohail.scribe.keyboard

import android.text.InputType
import android.view.View
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeyboardAccessibilityTest {
    @Test fun talkBackProviderExposesVirtualKeysAndHidesMicrophoneForPasswords() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val view = ScribeKeyboardView(instrumentation.targetContext)
            view.updateFieldProfile(
                KeyboardFieldProfile.from(
                    InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
                    0,
                ),
            )
            view.measure(
                View.MeasureSpec.makeMeasureSpec(1_080, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY),
            )
            view.layout(0, 0, 1_080, 900)

            val provider = view.accessibilityNodeProvider
            assertNotNull(provider)
            val firstKey = provider!!.createAccessibilityNodeInfo(0)
            assertNotNull(firstKey)
            assertEquals("q, alternate 1", firstKey!!.contentDescription.toString())
        }
    }

    @Test fun numberFieldExposesDedicatedNumberPadNodes() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val view = ScribeKeyboardView(instrumentation.targetContext)
            view.updateFieldProfile(
                KeyboardFieldProfile.from(
                    InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL,
                    0,
                ),
            )
            view.measure(
                View.MeasureSpec.makeMeasureSpec(1_080, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY),
            )
            view.layout(0, 0, 1_080, 900)

            val provider = view.accessibilityNodeProvider
            assertNotNull(provider)
            assertEquals("Start dictation", provider!!.createAccessibilityNodeInfo(0)?.contentDescription.toString())
            assertEquals("1", provider.createAccessibilityNodeInfo(1)?.contentDescription.toString())
        }
    }

    @Test fun correctionLearningPersistsAcceptsAndRejectionsPrivately() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.getSharedPreferences("scribe.autocorrection.learning", 0).edit().clear().commit()
        val first = KeyboardCorrectionLearningStore(context)
        first.recordAccepted("teh", "the")
        first.recordRejected("wrod", "word")

        val reloaded = KeyboardCorrectionLearningStore(context)
        assertEquals(
            1,
            reloaded.acceptedCountsSnapshot()[KeyboardCorrectionRanking.pairKey("teh", "the")],
        )
        assertEquals(true, "wrod" in reloaded.protectedWordsSnapshot())
    }

    @Test fun explicitAutocorrectionUndoIsExposedToTalkBack() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val view = ScribeKeyboardView(instrumentation.targetContext)
            view.updateAutocorrectionUndoOriginal("teh")
            view.measure(
                View.MeasureSpec.makeMeasureSpec(1_080, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY),
            )
            view.layout(0, 0, 1_080, 900)

            assertEquals(
                "Undo autocorrection to teh",
                view.accessibilityNodeProvider
                    ?.createAccessibilityNodeInfo(0)
                    ?.contentDescription
                    ?.toString(),
            )
        }
    }
}
