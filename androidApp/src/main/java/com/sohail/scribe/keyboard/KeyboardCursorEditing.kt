package com.sohail.scribe.keyboard

import android.view.inputmethod.InputConnection
import kotlin.math.absoluteValue

object KeyboardCursorEditing {
    /**
     * Moves a collapsed Android selection by Unicode code points and returns
     * the new UTF-16 selection index. Hosts that reject setSelection return
     * null so the IME can retain its key-event fallback.
     */
    fun moveCollapsedSelection(
        connection: InputConnection?,
        selectionStart: Int,
        selectionEnd: Int,
        characters: Int,
    ): Int? {
        if (connection == null || selectionStart < 0 || selectionStart != selectionEnd || characters == 0) {
            return null
        }
        val requestedCodePoints = characters.absoluteValue
        val utf16Units = if (characters < 0) {
            val text = connection.getTextBeforeCursor(requestedCodePoints * 2, 0)?.toString().orEmpty()
            utf16UnitsBefore(text, requestedCodePoints)
        } else {
            val text = connection.getTextAfterCursor(requestedCodePoints * 2, 0)?.toString().orEmpty()
            utf16UnitsAfter(text, requestedCodePoints)
        }
        if (utf16Units == 0) {
            // A left move at document offset zero is a known boundary. Empty
            // context anywhere else may mean the host withholds surrounding
            // text, so let the caller try the key-event fallback.
            return selectionStart.takeIf { characters < 0 && selectionStart == 0 }
        }
        val target = if (characters < 0) {
            (selectionStart - utf16Units).coerceAtLeast(0)
        } else {
            selectionStart + utf16Units
        }
        return target.takeIf { connection.setSelection(it, it) }
    }

    internal fun utf16UnitsBefore(text: String, codePointCount: Int): Int {
        var index = text.length
        repeat(codePointCount) {
            if (index == 0) return text.length
            index -= Character.charCount(Character.codePointBefore(text, index))
        }
        return text.length - index
    }

    internal fun utf16UnitsAfter(text: String, codePointCount: Int): Int {
        var index = 0
        repeat(codePointCount) {
            if (index == text.length) return text.length
            index += Character.charCount(Character.codePointAt(text, index))
        }
        return index
    }
}
