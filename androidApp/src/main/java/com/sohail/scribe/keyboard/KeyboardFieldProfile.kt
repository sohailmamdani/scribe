package com.sohail.scribe.keyboard

import android.text.InputType
import android.view.inputmethod.EditorInfo

enum class KeyboardFieldLayout { TEXT, NUMBER, PHONE, EMAIL, URI }

enum class KeyboardCapitalization { NONE, WORDS, SENTENCES, ALL_CHARACTERS }

enum class KeyboardReturnAction(val label: String) {
    RETURN("return"),
    DONE("done"),
    GO("go"),
    NEXT("next"),
    PREVIOUS("previous"),
    SEARCH("search"),
    SEND("send"),
}

data class KeyboardFieldProfile(
    val layout: KeyboardFieldLayout = KeyboardFieldLayout.TEXT,
    val returnAction: KeyboardReturnAction = KeyboardReturnAction.RETURN,
    val sensitive: Boolean = false,
    val allowsSuggestions: Boolean = true,
    val allowsDictation: Boolean = true,
    val allowsShift: Boolean = true,
    val capitalization: KeyboardCapitalization = KeyboardCapitalization.SENTENCES,
    val signedNumber: Boolean = false,
    val decimalNumber: Boolean = false,
) {
    companion object {
        fun from(inputType: Int, imeOptions: Int): KeyboardFieldProfile {
            val inputClass = inputType and InputType.TYPE_MASK_CLASS
            val variation = inputType and InputType.TYPE_MASK_VARIATION
            val sensitive = variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
                variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            val layout = when {
                inputClass == InputType.TYPE_CLASS_NUMBER -> KeyboardFieldLayout.NUMBER
                inputClass == InputType.TYPE_CLASS_PHONE -> KeyboardFieldLayout.PHONE
                inputClass == InputType.TYPE_CLASS_DATETIME -> KeyboardFieldLayout.NUMBER
                variation == InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS ||
                    variation == InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS -> KeyboardFieldLayout.EMAIL
                variation == InputType.TYPE_TEXT_VARIATION_URI -> KeyboardFieldLayout.URI
                else -> KeyboardFieldLayout.TEXT
            }
            val explicitlyDisablesSuggestions = inputType and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS != 0
            val textLayout = layout == KeyboardFieldLayout.TEXT
            return KeyboardFieldProfile(
                layout = layout,
                returnAction = returnActionFor(imeOptions),
                sensitive = sensitive,
                allowsSuggestions = textLayout && !sensitive && !explicitlyDisablesSuggestions,
                allowsDictation = !sensitive,
                allowsShift = layout == KeyboardFieldLayout.TEXT ||
                    layout == KeyboardFieldLayout.EMAIL || layout == KeyboardFieldLayout.URI,
                capitalization = capitalizationFor(inputType, layout),
                signedNumber = inputType and InputType.TYPE_NUMBER_FLAG_SIGNED != 0,
                decimalNumber = inputType and InputType.TYPE_NUMBER_FLAG_DECIMAL != 0,
            )
        }

        private fun capitalizationFor(
            inputType: Int,
            layout: KeyboardFieldLayout,
        ): KeyboardCapitalization {
            if (layout != KeyboardFieldLayout.TEXT) return KeyboardCapitalization.NONE
            return when {
                inputType and InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS != 0 ->
                    KeyboardCapitalization.ALL_CHARACTERS
                inputType and InputType.TYPE_TEXT_FLAG_CAP_WORDS != 0 ->
                    KeyboardCapitalization.WORDS
                inputType and InputType.TYPE_TEXT_FLAG_CAP_SENTENCES != 0 ->
                    KeyboardCapitalization.SENTENCES
                else -> KeyboardCapitalization.NONE
            }
        }

        private fun returnActionFor(imeOptions: Int): KeyboardReturnAction {
            if (imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0) {
                return KeyboardReturnAction.RETURN
            }
            return when (imeOptions and EditorInfo.IME_MASK_ACTION) {
                EditorInfo.IME_ACTION_DONE -> KeyboardReturnAction.DONE
                EditorInfo.IME_ACTION_GO -> KeyboardReturnAction.GO
                EditorInfo.IME_ACTION_NEXT -> KeyboardReturnAction.NEXT
                EditorInfo.IME_ACTION_PREVIOUS -> KeyboardReturnAction.PREVIOUS
                EditorInfo.IME_ACTION_SEARCH -> KeyboardReturnAction.SEARCH
                EditorInfo.IME_ACTION_SEND -> KeyboardReturnAction.SEND
                else -> KeyboardReturnAction.RETURN
            }
        }
    }
}

object KeyboardAccessibilityLabels {
    fun labelFor(id: String, visibleLabel: String, alternate: String? = null): String {
        val base = when (id) {
            "shift" -> "Shift"
            "delete" -> "Delete"
            "space" -> "Space"
            "return" -> visibleLabel.replaceFirstChar(Char::uppercase)
            "next" -> "Next keyboard"
            "microphone" -> if (visibleLabel == "Stop") "Stop dictation" else "Start dictation"
            "cancel" -> "Cancel dictation"
            "undo-dictation" -> "Undo last dictation"
            "undo-autocorrection" -> "Undo autocorrection to ${visibleLabel.removePrefix("Undo to ")}"
            "mode" -> if (visibleLabel == "ABC") "Letters" else "Numbers and symbols"
            "more-symbols" -> if (visibleLabel == "123") "Numbers" else "More symbols"
            "period" -> "Period"
            else -> punctuationName(visibleLabel) ?: visibleLabel
        }
        return if (alternate == null) {
            base
        } else {
            "$base, alternate ${punctuationName(alternate) ?: alternate}"
        }
    }

    private fun punctuationName(value: String): String? = KeyboardAlternateSymbols.spokenName(value) ?: when (value) {
        "." -> "Period"
        "," -> "Comma"
        "?" -> "Question mark"
        else -> null
    }
}
