package com.sohail.scribe.speech

import kotlin.test.Test
import kotlin.test.assertEquals

class RecognitionTranscriptAccumulatorTest {
    @Test fun joinsRecognizerSegmentsUntilTheUserStops() {
        val accumulator = RecognitionTranscriptAccumulator()

        assertEquals("First thought.", accumulator.append(" First thought. "))
        assertEquals("First thought. second thought", accumulator.preview("second thought"))
        assertEquals("First thought. Second thought.", accumulator.append("Second thought."))
    }

    @Test fun resetStartsANewManualDictation() {
        val accumulator = RecognitionTranscriptAccumulator()
        accumulator.append("Old dictation")

        accumulator.reset()

        assertEquals("", accumulator.text())
        assertEquals("New", accumulator.preview("New"))
    }
}
