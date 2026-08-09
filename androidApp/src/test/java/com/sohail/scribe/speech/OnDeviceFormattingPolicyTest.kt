package com.sohail.scribe.speech

import kotlin.test.Test
import kotlin.test.assertEquals

class OnDeviceFormattingPolicyTest {
    @Test fun keepsFaithfulOnDevicePunctuationAndCapitalization() {
        assertEquals(
            "Hello, world!",
            OnDeviceFormattingPolicy.bestResult(listOf("Hello, world!", "hello world")),
        )
    }

    @Test fun rejectsFormattedTextThatInventsOrReordersWords() {
        assertEquals(
            "hello world",
            OnDeviceFormattingPolicy.bestResult(listOf("Hello, bright world!", "hello world")),
        )
        assertEquals(
            "hello world",
            OnDeviceFormattingPolicy.bestResult(listOf("World, hello!", "hello world")),
        )
    }

    @Test fun singletonResultsRemainCompatibleWithRecognizersThatIgnoreFormatting() {
        assertEquals(
            "ordinary result",
            OnDeviceFormattingPolicy.bestResult(listOf("ordinary result")),
        )
        assertEquals(
            "raw result",
            OnDeviceFormattingPolicy.bestResult(listOf("", "raw result")),
        )
    }
}
