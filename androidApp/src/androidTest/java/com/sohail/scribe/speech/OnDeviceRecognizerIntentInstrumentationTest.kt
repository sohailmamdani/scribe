package com.sohail.scribe.speech

import android.speech.RecognizerIntent
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OnDeviceRecognizerIntentInstrumentationTest {
    @Test fun api33UsesQualityFormattingWithoutChangingTheOfflineContract() {
        val intent = onDeviceRecognizerIntent("en-US", sdkInt = 33)

        assertEquals("en-US", intent.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
        assertEquals(1, intent.getIntExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 0))
        assertTrue(intent.getBooleanExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false))
        assertEquals(
            RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY,
            intent.getStringExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING),
        )
        assertTrue(
            intent.getBooleanExtra(
                RecognizerIntent.EXTRA_HIDE_PARTIAL_TRAILING_PUNCTUATION,
                false,
            ),
        )
    }

    @Test fun api31KeepsTheOfflineRecognizerWithoutUnsupportedFormattingExtras() {
        val intent = onDeviceRecognizerIntent("en-US", sdkInt = 31)

        assertTrue(intent.getBooleanExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false))
        assertFalse(intent.hasExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING))
        assertFalse(intent.hasExtra(RecognizerIntent.EXTRA_HIDE_PARTIAL_TRAILING_PUNCTUATION))
    }

    @Test fun modelSupportIntentDoesNotRequireTheOptionalFormatter() {
        val intent = onDeviceRecognizerIntent(
            "en-US",
            sdkInt = 33,
            enableFormatting = false,
        )

        assertTrue(intent.getBooleanExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false))
        assertFalse(intent.hasExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING))
        assertFalse(intent.hasExtra(RecognizerIntent.EXTRA_HIDE_PARTIAL_TRAILING_PUNCTUATION))
    }

    @Test fun userOptOutKeepsOnDeviceRecognitionWithoutFormattingExtras() {
        val intent = onDeviceRecognizerIntent(
            "en-US",
            sdkInt = 36,
            enableFormatting = false,
        )

        assertTrue(intent.getBooleanExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false))
        assertFalse(intent.hasExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING))
        assertFalse(intent.hasExtra(RecognizerIntent.EXTRA_HIDE_PARTIAL_TRAILING_PUNCTUATION))
    }
}
