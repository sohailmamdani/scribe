package com.sohail.scribe.keyboard

import com.sohail.scribe.speech.SpeechSessionState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class KeyboardDictationControlPolicyTest {
    @Test fun idleListeningFailureAndCompletionExposeTheRightAction() {
        assertEquals(
            KeyboardDictationControl("Dictate", true),
            KeyboardDictationControlPolicy.control(SpeechSessionState.IDLE),
        )
        assertEquals(
            KeyboardDictationControl("Stop", true),
            KeyboardDictationControlPolicy.control(SpeechSessionState.LISTENING),
        )
        assertEquals(
            KeyboardDictationControl("Retry", true),
            KeyboardDictationControlPolicy.control(SpeechSessionState.FAILED),
        )
        assertEquals(
            KeyboardDictationControl("Dictate", true),
            KeyboardDictationControlPolicy.control(SpeechSessionState.COMPLETED),
        )
    }

    @Test fun preparationAndProcessingExposeStatusWithoutAnAction() {
        listOf(SpeechSessionState.PREPARING, SpeechSessionState.PROCESSING).forEach { state ->
            val control = KeyboardDictationControlPolicy.control(state)
            assertFalse(control.enabled)
        }
        assertEquals("Starting", KeyboardDictationControlPolicy.control(SpeechSessionState.PREPARING).label)
        assertEquals("Finishing", KeyboardDictationControlPolicy.control(SpeechSessionState.PROCESSING).label)
        assertTrue(KeyboardDictationControlPolicy.control(SpeechSessionState.FAILED).enabled)
    }
}
