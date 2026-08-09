package com.sohail.scribe.keyboard

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class KeyboardSelectionEditingTest {
    @Test fun selectionRequiresTwoValidDistinctEndpoints() {
        assertTrue(KeyboardSelectionEditing.hasSelection(2, 7))
        assertTrue(KeyboardSelectionEditing.hasSelection(7, 2))
        assertFalse(KeyboardSelectionEditing.hasSelection(4, 4))
        assertFalse(KeyboardSelectionEditing.hasSelection(-1, -1))
    }
}
