package com.sohail.scribe.keyboard

/** Alternates printed on the supplied Gboard Android reference. */
object KeyboardAlternateSymbols {
    private val values = mapOf(
        '1' to "!", '2' to "@", '3' to "#", '4' to "$", '5' to "%",
        '6' to "^", '7' to "&", '8' to "*", '9' to "(", '0' to ")",
        'q' to "%", 'w' to "\\", 'e' to "|", 'r' to "=", 't' to "[",
        'y' to "]", 'u' to "<", 'i' to ">", 'o' to "{", 'p' to "}",
        'a' to "@", 's' to "#", 'd' to "$", 'f' to "_", 'g' to "&",
        'h' to "-", 'j' to "+", 'k' to "(", 'l' to ")",
        'z' to "*", 'x' to "\"", 'c' to "'", 'v' to ":", 'b' to ";",
        'n' to "!", 'm' to "?",
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
        "\\" -> "Backslash"
        "|" -> "Vertical bar"
        "[" -> "Left bracket"
        "]" -> "Right bracket"
        "<" -> "Less than"
        ">" -> "Greater than"
        "{" -> "Left brace"
        "}" -> "Right brace"
        "_" -> "Underscore"
        "?" -> "Question mark"
        else -> null
    }
}
