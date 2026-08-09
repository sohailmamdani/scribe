package com.sohail.scribe.speech

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SpeechCallbackGateTest {
    @Test fun replacingARecognizerRejectsEveryCallbackFromTheOldOne() {
        val gate = SpeechCallbackGate()
        val supportCheck = gate.begin()
        assertTrue(gate.accepts(supportCheck))

        val liveDictation = gate.begin()
        assertFalse(gate.accepts(supportCheck))
        assertTrue(gate.accepts(liveDictation))

        gate.invalidate()
        assertFalse(gate.accepts(liveDictation))
    }
}
