package com.sohail.scribe.core

object KeyboardEditingRules {
    fun currentWord(contextBefore: CharSequence?): String? {
        val word = contextBefore
            ?.takeLastWhile { it.isLetter() || it == '\'' || it == '’' }
            ?.toString()
            .orEmpty()
        return word.takeIf { it.length >= 2 && it.any(Char::isLetter) }
    }

    fun shouldCapitalize(contextBefore: CharSequence?): Boolean {
        if (contextBefore.isNullOrEmpty()) return true
        if (contextBefore.last() == '\n') return true
        val lastNonWhitespace = contextBefore.lastOrNull { !it.isWhitespace() } ?: return true
        return lastNonWhitespace in ".!?"
    }

    fun shouldCapitalizeWord(contextBefore: CharSequence?): Boolean =
        contextBefore.isNullOrEmpty() || contextBefore.last().isWhitespace()

    fun shouldReplaceDoubleSpace(contextBefore: CharSequence?): Boolean {
        val text = contextBefore?.toString() ?: return false
        if (!text.endsWith(" ")) return false
        val preceding = text.dropLast(1).lastOrNull() ?: return false
        return preceding.isLetterOrDigit() || preceding in ")]}'\"”’"
    }

    fun deleteWordCodePointCount(contextBefore: CharSequence?): Int {
        val text = contextBefore?.toString().orEmpty()
        if (text.isEmpty()) return 1
        var index = text.length
        var count = 0
        while (index > 0) {
            val codePoint = Character.codePointBefore(text, index)
            if (!Character.isWhitespace(codePoint)) break
            index -= Character.charCount(codePoint)
            count += 1
        }
        while (index > 0) {
            val codePoint = Character.codePointBefore(text, index)
            if (Character.isWhitespace(codePoint)) break
            index -= Character.charCount(codePoint)
            count += 1
        }
        return count.coerceAtLeast(1)
    }

    fun shouldReturnToLetters(
        behavior: SymbolTapBehavior,
        scope: SymbolTapScope,
        onSymbolsPage: Boolean,
    ): Boolean = behavior == SymbolTapBehavior.RETURN_TO_LETTERS &&
        (scope == SymbolTapScope.NUMBERS_AND_SYMBOLS || onSymbolsPage)
}
