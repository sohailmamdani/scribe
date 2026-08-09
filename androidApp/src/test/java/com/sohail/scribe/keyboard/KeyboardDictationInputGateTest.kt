package com.sohail.scribe.keyboard

import com.sohail.scribe.speech.SpeechSessionState
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class KeyboardDictationInputGateTest {
    @Test fun cancelsEveryInFlightStateIncludingProcessing() {
        assertTrue(KeyboardDictationInputGate.shouldCancel(SpeechSessionState.PREPARING))
        assertTrue(KeyboardDictationInputGate.shouldCancel(SpeechSessionState.LISTENING))
        assertTrue(KeyboardDictationInputGate.shouldCancel(SpeechSessionState.PROCESSING))
        assertFalse(KeyboardDictationInputGate.shouldCancel(SpeechSessionState.IDLE))
        assertFalse(KeyboardDictationInputGate.shouldCancel(SpeechSessionState.COMPLETED))
        assertFalse(KeyboardDictationInputGate.shouldCancel(SpeechSessionState.FAILED))
    }

    @Test fun acceptsOneResultFromTheInputThatStartedDictation() {
        val gate = KeyboardDictationInputGate()
        gate.beginInput()
        gate.bindSession()

        assertTrue(gate.acceptsCallback(allowsDictation = true))
        assertTrue(gate.consumeResult(allowsDictation = true))
        assertFalse(gate.consumeResult(allowsDictation = true))
    }

    @Test fun rejectsAResultAfterAndroidMovesToAnotherInput() {
        val gate = KeyboardDictationInputGate()
        gate.beginInput()
        gate.bindSession()

        gate.beginInput()

        assertFalse(gate.acceptsCallback(allowsDictation = true))
        assertFalse(gate.consumeResult(allowsDictation = true))
    }

    @Test fun rejectsAndConsumesAResultWhenTheCurrentFieldDisallowsDictation() {
        val gate = KeyboardDictationInputGate()
        gate.beginInput()
        gate.bindSession()

        assertFalse(gate.consumeResult(allowsDictation = false))
        assertFalse(gate.acceptsCallback(allowsDictation = true))
    }
}
