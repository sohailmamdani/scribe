package com.sohail.scribe.keyboard

import kotlin.test.Test
import kotlin.test.assertEquals

class KeyboardCursorEditingTest {
    @Test fun backwardOffsetsKeepSurrogatePairsWhole() {
        assertEquals(1, KeyboardCursorEditing.utf16UnitsBefore("ab", 1))
        assertEquals(3, KeyboardCursorEditing.utf16UnitsBefore("a😀", 2))
    }

    @Test fun forwardOffsetsKeepSurrogatePairsWhole() {
        assertEquals(2, KeyboardCursorEditing.utf16UnitsAfter("😀b", 1))
        assertEquals(3, KeyboardCursorEditing.utf16UnitsAfter("😀b", 2))
    }

    @Test fun offsetsClampToTheAvailableContext() {
        assertEquals(3, KeyboardCursorEditing.utf16UnitsBefore("a😀", 9))
        assertEquals(3, KeyboardCursorEditing.utf16UnitsAfter("😀b", 9))
    }
}
