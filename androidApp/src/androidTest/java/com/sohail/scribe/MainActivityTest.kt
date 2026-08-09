package com.sohail.scribe

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import org.junit.Rule
import org.junit.Test

class MainActivityTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun setupAndSettingsFlowsExposeTheParityControls() {
        compose.onNodeWithText("Tap to dictate").assertIsDisplayed()
        compose.onNodeWithText("Try the keyboard").assertIsDisplayed()
        compose.onNodeWithText("Private by design").performScrollTo().assertIsDisplayed()

        compose.onNodeWithContentDescription("Keyboard settings").performClick()
        compose.onNodeWithText("Autocorrection").assertIsDisplayed()
        compose.onNodeWithText("Swipe typing").assertIsDisplayed()
        compose.onNodeWithText("Alternate symbols").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Keyboard haptics").performScrollTo().assertIsDisplayed()
    }
}
