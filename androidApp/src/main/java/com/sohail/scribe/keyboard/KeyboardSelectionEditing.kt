package com.sohail.scribe.keyboard

import android.view.inputmethod.InputConnection
import android.view.KeyEvent

/** Selection behavior shared by host apps that expose different InputConnection implementations. */
object KeyboardSelectionEditing {
    fun hasSelection(start: Int, end: Int): Boolean = start >= 0 && end >= 0 && start != end

    fun deleteSelection(connection: InputConnection?, start: Int, end: Int): Boolean {
        if (!hasSelection(start, end)) return false
        if (connection?.commitText("", 1) == true) return true
        val down = connection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL)) == true
        val up = connection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL)) == true
        return down || up
    }
}
