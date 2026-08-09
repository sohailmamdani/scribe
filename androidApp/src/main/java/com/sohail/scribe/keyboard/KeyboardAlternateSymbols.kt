package com.sohail.scribe.keyboard

/** Exact Android counterpart of the alternates exposed by the iOS keyboard. */
object KeyboardAlternateSymbols {
    private val values = mapOf(
        '1' to "!", '2' to "@", '3' to "#", '4' to "$", '5' to "%",
        '6' to "^", '7' to "&", '8' to "*", '9' to "(", '0' to ")",
        'q' to "1", 'w' to "2", 'e' to "3", 'r' to "4", 't' to "5",
        'y' to "6", 'u' to "7", 'i' to "8", 'o' to "9", 'p' to "0",
        'a' to "@", 's' to "#", 'd' to "$", 'f' to "&", 'g' to "*",
        'h' to "(", 'j' to ")", 'k' to "'", 'l' to "\"",
        'z' to "%", 'x' to "-", 'c' to "+", 'v' to "=", 'b' to "/",
        'n' to ";", 'm' to ":",
    )

    fun alternateFor(character: Char): String? = values[character.lowercaseChar()]

    fun spokenName(value: String): String? = when (value) {
        "!" -> "Exclamation mark"
        "@" -> "At sign"
        "#" -> "Number sign"
        "$" -> "Dollar sign"
        "%" -> "Percent sign"
        "^" -> "Caret"
        "&" -> "Ampersand"
        "*" -> "Asterisk"
        "(" -> "Left parenthesis"
        ")" -> "Right parenthesis"
        "'" -> "Apostrophe"
        "\"" -> "Quotation mark"
        "-" -> "Hyphen"
        "+" -> "Plus sign"
        "=" -> "Equals sign"
        "/" -> "Slash"
        ";" -> "Semicolon"
        ":" -> "Colon"
        else -> null
    }
}
