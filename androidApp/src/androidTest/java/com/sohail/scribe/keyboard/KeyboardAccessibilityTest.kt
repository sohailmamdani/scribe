package com.sohail.scribe.keyboard

import android.text.InputType
import android.graphics.Rect
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.BaseInputConnection
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.sohail.scribe.core.KeyboardPreferences
import com.sohail.scribe.core.SymbolTapBehavior
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeyboardAccessibilityTest {
    @Test fun disablingAlternatesAlsoRemovesTheTalkBackAction() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val view = ScribeKeyboardView(instrumentation.targetContext)
            view.updatePreferences(KeyboardPreferences(alternateSymbolsEnabled = false))
            view.measure(
                View.MeasureSpec.makeMeasureSpec(1_080, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY),
            )
            view.layout(0, 0, 1_080, 900)

            val provider = view.accessibilityNodeProvider!!
            assertEquals("Q", provider.createAccessibilityNodeInfo(1)?.contentDescription?.toString())
            assertEquals(false, provider.performAction(1, AccessibilityNodeInfo.ACTION_LONG_CLICK, null))
            val periodIndex = (0 until 64).first { index ->
                provider.createAccessibilityNodeInfo(index)?.contentDescription?.toString() == "Period"
            }
            assertEquals(null, provider.createAccessibilityNodeInfo(periodIndex)?.hintText)
        }
    }

    @Test fun quickSpaceDragTypesSpaceInsteadOfMovingTheCursor() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val listener = RecordingKeyboardListener()
        instrumentation.runOnMainSync {
            val view = measuredKeyboardView(instrumentation.targetContext, listener)
            val bounds = virtualKeyBounds(view, "Space")
            val downTime = SystemClock.uptimeMillis()
            view.onTouchEvent(MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, bounds.exactCenterX(), bounds.exactCenterY(), 0))
            view.onTouchEvent(MotionEvent.obtain(downTime, downTime + 40, MotionEvent.ACTION_MOVE, bounds.exactCenterX() + 48, bounds.exactCenterY(), 0))
            view.onTouchEvent(MotionEvent.obtain(downTime, downTime + 80, MotionEvent.ACTION_UP, bounds.exactCenterX() + 48, bounds.exactCenterY(), 0))
        }

        assertEquals(1, listener.spaces)
        assertEquals(0, listener.cursorMovement)
    }

    @Test fun heldSpaceDragMovesTheCursorWithoutTypingSpace() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val listener = RecordingKeyboardListener()
        lateinit var view: ScribeKeyboardView
        lateinit var bounds: Rect
        val downTime = SystemClock.uptimeMillis()
        instrumentation.runOnMainSync {
            view = measuredKeyboardView(instrumentation.targetContext, listener)
            bounds = virtualKeyBounds(view, "Space")
            view.onTouchEvent(MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, bounds.exactCenterX(), bounds.exactCenterY(), 0))
        }
        Thread.sleep(KeyboardGestureRules.SPACE_CURSOR_HOLD_MILLIS + 150L)
        instrumentation.runOnMainSync {
            val eventTime = SystemClock.uptimeMillis()
            view.onTouchEvent(MotionEvent.obtain(downTime, eventTime, MotionEvent.ACTION_MOVE, bounds.exactCenterX() + 48, bounds.exactCenterY(), 0))
            view.onTouchEvent(MotionEvent.obtain(downTime, eventTime + 20, MotionEvent.ACTION_UP, bounds.exactCenterX() + 48, bounds.exactCenterY(), 0))
        }

        assertEquals(0, listener.spaces)
        assertTrue(listener.cursorMovement > 0)
    }

    @Test fun punctuationHoldUsesPreferencesAndReturnsToLetters() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val listener = RecordingKeyboardListener()
        lateinit var view: ScribeKeyboardView
        lateinit var bounds: Rect
        val downTime = SystemClock.uptimeMillis()
        instrumentation.runOnMainSync {
            view = measuredKeyboardView(
                instrumentation.targetContext,
                listener,
                KeyboardPreferences(
                    alternateHoldDelayMillis = 250,
                    symbolTapBehavior = SymbolTapBehavior.RETURN_TO_LETTERS,
                ),
            )
            val provider = view.accessibilityNodeProvider!!
            val modeIndex = (0 until 64).first { index ->
                provider.createAccessibilityNodeInfo(index)?.contentDescription?.toString() ==
                    "Numbers and symbols"
            }
            provider.performAction(modeIndex, AccessibilityNodeInfo.ACTION_CLICK, null)
            bounds = virtualKeyBounds(view, "Period")
            view.onTouchEvent(MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, bounds.exactCenterX(), bounds.exactCenterY(), 0))
        }
        Thread.sleep(400L)
        instrumentation.runOnMainSync {
            val eventTime = SystemClock.uptimeMillis()
            view.onTouchEvent(MotionEvent.obtain(downTime, eventTime, MotionEvent.ACTION_UP, bounds.exactCenterX(), bounds.exactCenterY(), 0))
            assertTrue(
                view.accessibilityNodeProvider
                    ?.createAccessibilityNodeInfo(1)
                    ?.contentDescription
                    ?.toString()
                    ?.startsWith("Q") == true,
            )
        }

        assertEquals(listOf("."), listener.texts)
    }

    @Test fun selectedTextIsDeletedAsASelectionInsteadOfBeforeTheCaret() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val connection = BaseInputConnection(View(instrumentation.targetContext), true)
            connection.commitText("hello world", 1)
            connection.setSelection(0, 5)

            assertEquals(true, KeyboardSelectionEditing.deleteSelection(connection, 0, 5))
            assertEquals(" world", connection.editable.toString())
        }
    }

    @Test fun cursorMovementUsesHostSelectionAndKeepsEmojiWhole() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val connection = BaseInputConnection(View(instrumentation.targetContext), true)
            connection.commitText("a😀bc", 1)
            connection.setSelection(5, 5)

            assertEquals(3, KeyboardCursorEditing.moveCollapsedSelection(connection, 5, 5, -2))
            connection.commitText("X", 1)
            assertEquals("a😀Xbc", connection.editable.toString())
        }
    }

    @Test fun numbersPageExposesTheSameDigitAlternatesAsIos() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val view = ScribeKeyboardView(instrumentation.targetContext)
            view.measure(
                View.MeasureSpec.makeMeasureSpec(1_080, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY),
            )
            view.layout(0, 0, 1_080, 900)

            val provider = view.accessibilityNodeProvider!!
            val modeIndex = (0 until 64).first { index ->
                provider.createAccessibilityNodeInfo(index)?.contentDescription?.toString() ==
                    "Numbers and symbols"
            }
            provider.performAction(modeIndex, AccessibilityNodeInfo.ACTION_CLICK, null)

            assertEquals(
                "1, alternate Exclamation mark",
                provider.createAccessibilityNodeInfo(1)?.contentDescription?.toString(),
            )
        }
    }

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

    private fun measuredKeyboardView(
        context: android.content.Context,
        actionListener: KeyboardActionListener,
        preferences: KeyboardPreferences = KeyboardPreferences(),
    ) = ScribeKeyboardView(context).apply {
        listener = actionListener
        updatePreferences(preferences)
        measure(
            View.MeasureSpec.makeMeasureSpec(1_080, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY),
        )
        layout(0, 0, 1_080, 900)
    }

    @Suppress("DEPRECATION") // The virtual-key provider exposes parent-relative test bounds.
    private fun virtualKeyBounds(view: ScribeKeyboardView, label: String): Rect {
        val provider = view.accessibilityNodeProvider!!
        val index = (0 until 64).first { candidate ->
            provider.createAccessibilityNodeInfo(candidate)?.contentDescription?.toString() == label
        }
        return Rect().also { provider.createAccessibilityNodeInfo(index)!!.getBoundsInParent(it) }
    }

    private class RecordingKeyboardListener : KeyboardActionListener {
        val texts = mutableListOf<String>()
        var spaces = 0
        var cursorMovement = 0

        override fun onText(text: String, isLetter: Boolean, evidence: KeyboardTapEvidence?) {
            texts += text
        }

        override fun onDelete() = Unit
        override fun onDeleteWord() = Unit
        override fun onSpace() { spaces += 1 }
        override fun onEnter() = Unit
        override fun onMoveCursor(characters: Int) { cursorMovement += characters }
        override fun onSwipe(keys: List<Char>, capitalize: Boolean) = Unit
        override fun onSuggestion(candidate: CorrectionCandidate) = Unit
        override fun onUndoAutocorrection() = Unit
        override fun onNextInputMethod() = Unit
        override fun onToggleDictation() = Unit
        override fun onCancelDictation() = Unit
        override fun onUndoDictation() = Unit
    }
}
