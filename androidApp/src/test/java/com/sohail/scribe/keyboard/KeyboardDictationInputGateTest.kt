package com.sohail.scribe.keyboard

import com.sohail.scribe.speech.SpeechSessionState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class KeyboardDictationInputGateTest {
    @Test fun letsStoppedProcessingFinishForExplicitRecovery() {
        assertTrue(KeyboardDictationInputGate.shouldCancel(SpeechSessionState.PREPARING))
        assertTrue(KeyboardDictationInputGate.shouldCancel(SpeechSessionState.LISTENING))
        assertFalse(KeyboardDictationInputGate.shouldCancel(SpeechSessionState.PROCESSING))
        assertFalse(KeyboardDictationInputGate.shouldCancel(SpeechSessionState.IDLE))
        assertFalse(KeyboardDictationInputGate.shouldCancel(SpeechSessionState.COMPLETED))
        assertFalse(KeyboardDictationInputGate.shouldCancel(SpeechSessionState.FAILED))
    }

    @Test fun acceptsOneResultFromTheInputThatStartedDictation() {
        val gate = KeyboardDictationInputGate()
        gate.beginInput()
        gate.bindSession()

        assertTrue(gate.acceptsCallback(allowsDictation = true))
        assertTrue(gate.hasSession())
        assertEquals(
            KeyboardDictationResultDisposition.CURRENT_INPUT,
            gate.consumeResult(allowsDictation = true),
        )
        assertEquals(
            KeyboardDictationResultDisposition.REJECTED,
            gate.consumeResult(allowsDictation = true),
        )
    }

    @Test fun rejectsAResultAfterAndroidMovesToAnotherInput() {
        val gate = KeyboardDictationInputGate()
        gate.beginInput()
        gate.bindSession()

        gate.beginInput()

        assertFalse(gate.acceptsCallback(allowsDictation = true))
        assertTrue(gate.hasSession())
        assertEquals(
            KeyboardDictationResultDisposition.RECOVERABLE,
            gate.consumeResult(allowsDictation = true),
        )
    }

    @Test fun rejectsAndConsumesAResultWhenTheCurrentFieldDisallowsDictation() {
        val gate = KeyboardDictationInputGate()
        gate.beginInput()
        gate.bindSession()

        assertEquals(
            KeyboardDictationResultDisposition.RECOVERABLE,
            gate.consumeResult(allowsDictation = false),
        )
        assertFalse(gate.acceptsCallback(allowsDictation = true))
    }

    @Test fun clearingACancelledSessionRejectsItsLateResult() {
        val gate = KeyboardDictationInputGate()
        gate.beginInput()
        gate.bindSession()
        gate.clearSession()

        assertFalse(gate.hasSession())
        assertEquals(
            KeyboardDictationResultDisposition.REJECTED,
            gate.consumeResult(allowsDictation = true),
        )
    }
}
