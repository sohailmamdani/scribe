package com.sohail.scribe.core

object KeyboardEditingRules {
    private val preferredContractions = mapOf(
        "aint" to "ain't", "arent" to "aren't", "cant" to "can't",
        "couldnt" to "couldn't", "couldve" to "could've", "didnt" to "didn't",
        "doesnt" to "doesn't", "dont" to "don't", "hadnt" to "hadn't",
        "hasnt" to "hasn't", "havent" to "haven't", "heres" to "here's",
        "hows" to "how's", "im" to "I'm", "isnt" to "isn't", "itll" to "it'll",
        "ive" to "I've", "mightnt" to "mightn't", "mightve" to "might've",
        "mustnt" to "mustn't", "mustve" to "must've", "neednt" to "needn't",
        "shes" to "she's", "shouldnt" to "shouldn't", "shouldve" to "should've",
        "thats" to "that's", "theres" to "there's", "theyll" to "they'll",
        "theyre" to "they're", "theyve" to "they've", "wasnt" to "wasn't",
        "werent" to "weren't", "weve" to "we've", "whats" to "what's",
        "whens" to "when's", "wheres" to "where's", "whod" to "who'd",
        "wholl" to "who'll", "whos" to "who's", "whyd" to "why'd",
        "wont" to "won't", "wouldnt" to "wouldn't", "wouldve" to "would've",
        "yall" to "y'all", "youll" to "you'll", "youre" to "you're",
        "youve" to "you've",
    )

    fun currentWord(contextBefore: CharSequence?): String? {
        val word = contextBefore
            ?.takeLastWhile { it.isLetter() || it == '\'' || it == '’' }
            ?.toString()
            .orEmpty()
        return word.takeIf {
            it.length >= 2 && it.any(Char::isLetter) && !hasUnexpectedCapitalization(it)
        }
    }

    fun previousWord(contextBefore: CharSequence?): String? {
        var remaining = contextBefore?.toString().orEmpty()
        while (remaining.lastOrNull()?.let { it.isLetter() || it == '\'' || it == '’' } == true) {
            remaining = remaining.dropLast(1)
        }
        while (remaining.lastOrNull()?.isLetter() == false && remaining.isNotEmpty()) {
            remaining = remaining.dropLast(1)
        }
        val word = remaining.takeLastWhile { it.isLetter() || it == '\'' || it == '’' }
        return word.takeIf(String::isNotEmpty)
    }

    fun preferredContraction(word: String): String? = preferredContractions[word.lowercase()]

    fun isSafeCorrectionWord(word: String): Boolean =
        word.isNotEmpty() && word.all { it.isLetter() || it == '\'' || it == '’' }

    fun shouldCapitalize(contextBefore: CharSequence?): Boolean {
        if (contextBefore.isNullOrEmpty()) return true
        if (contextBefore.last() == '\n') return true
        val lastNonWhitespace = contextBefore.lastOrNull { !it.isWhitespace() } ?: return true
        return lastNonWhitespace in ".!?"
    }

    fun shouldCapitalizeWord(contextBefore: CharSequence?): Boolean =
        contextBefore.isNullOrEmpty() || contextBefore.last().isWhitespace()

    fun shouldReplaceDoubleSpace(
        contextBefore: CharSequence?,
        elapsedSincePreviousSpaceMillis: Long? = null,
    ): Boolean {
        if (elapsedSincePreviousSpaceMillis == null || elapsedSincePreviousSpaceMillis !in 0..550) {
            return false
        }
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

    /** Matches the iOS swipe-word boundary rule without forcing trailing space. */
    fun needsLeadingSpaceAfter(character: Char): Boolean =
        !character.isWhitespace() && character !in "([{\"'“‘@#$/_-–—"

    private fun hasUnexpectedCapitalization(word: String): Boolean {
        val letters = word.filter(Char::isLetter)
        if (letters.length <= 1) return false
        return letters == letters.uppercase() || letters.drop(1).any(Char::isUpperCase)
    }
}
