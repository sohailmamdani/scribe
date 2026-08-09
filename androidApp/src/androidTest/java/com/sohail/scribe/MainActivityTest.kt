package com.sohail.scribe

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import org.junit.Rule
import org.junit.Test

class MainActivityTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun setupAndSettingsFlowsExposeTheParityControls() {
        compose.onNodeWithText("Tap to dictate").assertIsDisplayed()
        compose.onNodeWithContentDescription("Start dictation").assertIsDisplayed()
        compose.onNodeWithText("Try the keyboard").assertIsDisplayed()
        scrollTo("home-list", "Private by design")

        compose.onNodeWithContentDescription("Keyboard settings").performClick()
        compose.onNodeWithText("Enhanced on-device punctuation").assertIsDisplayed()
        compose.onNodeWithText("Autocorrection").assertIsDisplayed()
        compose.onNodeWithText("Swipe typing").assertIsDisplayed()
        scrollTo("settings-list", "Alternate symbols")
        scrollTo("settings-list", "Keyboard haptics")
    }

    private fun scrollTo(containerTag: String, text: String) {
        compose.onNodeWithTag(containerTag).performScrollToNode(hasText(text))
        compose.onNodeWithText(text).assertIsDisplayed()
    }
}
