package com.sohail.scribe.keyboard

import com.sohail.scribe.core.KeyboardEditingRules

object KeyboardSwipeInsertion {
    fun text(decodedWord: String, contextBefore: CharSequence?, capitalize: Boolean): String {
        val word = if (capitalize) decodedWord.replaceFirstChar(Char::uppercase) else decodedWord
        val needsLeadingSpace = contextBefore?.lastOrNull()
            ?.let(KeyboardEditingRules::needsLeadingSpaceAfter) == true
        return (if (needsLeadingSpace) " " else "") + word
    }
}
