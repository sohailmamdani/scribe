package com.sohail.scribe.keyboard

import kotlin.test.Test
import kotlin.test.assertEquals

class KeyboardAlternateSymbolsTest {
    @Test fun mappingsMatchTheSuppliedGboardReference() {
        val expected = mapOf(
            '1' to "!", '2' to "@", '3' to "#", '4' to "$", '5' to "%",
            '6' to "^", '7' to "&", '8' to "*", '9' to "(", '0' to ")",
            'q' to "%", 'w' to "\\", 'e' to "|", 'r' to "=", 't' to "[",
            'y' to "]", 'u' to "<", 'i' to ">", 'o' to "{", 'p' to "}",
            'a' to "@", 's' to "#", 'd' to "$", 'f' to "_", 'g' to "&",
            'h' to "-", 'j' to "+", 'k' to "(", 'l' to ")",
            'z' to "*", 'x' to "\"", 'c' to "'", 'v' to ":", 'b' to ";",
            'n' to "!", 'm' to "?",
        )

        expected.forEach { (primary, alternate) ->
            assertEquals(alternate, KeyboardAlternateSymbols.alternateFor(primary))
            if (primary.isLetter()) {
                assertEquals(alternate, KeyboardAlternateSymbols.alternateFor(primary.uppercaseChar()))
            }
        }
    }

    @Test fun spokenNamesCoverTheFullPunctuationSet() {
        assertEquals("Dollar sign", KeyboardAlternateSymbols.spokenName("$"))
        assertEquals("Left parenthesis", KeyboardAlternateSymbols.spokenName("("))
        assertEquals("Equals sign", KeyboardAlternateSymbols.spokenName("="))
    }
}
