package com.sohail.scribe.keyboard

import android.text.InputType
import android.view.inputmethod.EditorInfo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class KeyboardFieldProfileTest {
    @Test fun textActionsMatchEditorContract() {
        assertEquals(
            KeyboardReturnAction.SEARCH,
            profile(InputType.TYPE_CLASS_TEXT, EditorInfo.IME_ACTION_SEARCH).returnAction,
        )
        assertEquals(
            KeyboardReturnAction.RETURN,
            profile(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE,
                EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_ENTER_ACTION,
            ).returnAction,
        )
    }

    @Test fun numberAndPhoneFieldsUseDedicatedLayouts() {
        val number = profile(
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_SIGNED or
                InputType.TYPE_NUMBER_FLAG_DECIMAL,
        )
        assertEquals(KeyboardFieldLayout.NUMBER, number.layout)
        assertTrue(number.signedNumber)
        assertTrue(number.decimalNumber)
        assertFalse(number.allowsShift)

        val phone = profile(InputType.TYPE_CLASS_PHONE)
        assertEquals(KeyboardFieldLayout.PHONE, phone.layout)
        assertFalse(phone.allowsSuggestions)
    }

    @Test fun emailAndUriFieldsExposePurposeBuiltPunctuation() {
        assertEquals(
            KeyboardFieldLayout.EMAIL,
            profile(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS).layout,
        )
        assertEquals(
            KeyboardFieldLayout.URI,
            profile(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI).layout,
        )
    }

    @Test fun everyPasswordVariationDisablesSuggestionsAndDictation() {
        val variations = listOf(
            InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
        )
        variations.forEach { variation ->
            val result = profile(InputType.TYPE_CLASS_TEXT or variation)
            assertTrue(result.sensitive)
            assertFalse(result.allowsSuggestions)
            assertFalse(result.allowsDictation)
        }
        val numericPassword = profile(
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD,
        )
        assertTrue(numericPassword.sensitive)
        assertEquals(KeyboardFieldLayout.NUMBER, numericPassword.layout)
    }

    @Test fun hostNoSuggestionsFlagIsRespected() {
        val result = profile(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS)
        assertFalse(result.allowsSuggestions)
        assertTrue(result.allowsDictation)
    }

    @Test fun hostNoPersonalizedLearningFlagDisablesHistoryAndCorrectionLearning() {
        val result = profile(
            InputType.TYPE_CLASS_TEXT,
            EditorInfo.IME_ACTION_NONE or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING,
        )
        assertFalse(result.allowsPersonalizedLearning)
        assertTrue(result.allowsSuggestions)
        assertTrue(profile(InputType.TYPE_CLASS_TEXT).allowsPersonalizedLearning)
    }

    @Test fun capitalizationFlagsMapWithoutAffectingEmailOrNumericFields() {
        assertEquals(
            KeyboardCapitalization.ALL_CHARACTERS,
            profile(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS).capitalization,
        )
        assertEquals(
            KeyboardCapitalization.WORDS,
            profile(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_WORDS).capitalization,
        )
        assertEquals(
            KeyboardCapitalization.SENTENCES,
            profile(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES).capitalization,
        )
        assertEquals(
            KeyboardCapitalization.NONE,
            profile(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS or
                InputType.TYPE_TEXT_FLAG_CAP_SENTENCES).capitalization,
        )
    }

    @Test fun accessibilityLabelsNameControlsAndAlternates() {
        assertEquals("Search", KeyboardAccessibilityLabels.labelFor("return", "search"))
        assertEquals("Start dictation", KeyboardAccessibilityLabels.labelFor("microphone", "Dictate"))
        assertEquals("Stop dictation", KeyboardAccessibilityLabels.labelFor("microphone", "Stop"))
        assertEquals(
            "Undo autocorrection to teh",
            KeyboardAccessibilityLabels.labelFor("undo-autocorrection", "Undo to teh"),
        )
        assertEquals("A, alternate At sign", KeyboardAccessibilityLabels.labelFor("key-a", "A", "@"))
        assertEquals("Question mark", KeyboardAccessibilityLabels.labelFor("symbol-?-0", "?"))
    }

    private fun profile(inputType: Int, imeOptions: Int = EditorInfo.IME_ACTION_NONE) =
        KeyboardFieldProfile.from(inputType, imeOptions)
}
