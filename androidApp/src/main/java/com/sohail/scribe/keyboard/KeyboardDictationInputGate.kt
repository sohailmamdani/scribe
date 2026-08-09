package com.sohail.scribe.keyboard

import com.sohail.scribe.speech.SpeechSessionState

internal enum class KeyboardDictationResultDisposition {
    CURRENT_INPUT,
    RECOVERABLE,
    REJECTED,
}

/**
 * Binds a keyboard dictation session to the editor that was active when it began.
 *
 * Speech callbacks are already generation-gated inside the recognizer. This
 * second gate protects the document boundary: a final result must never be
 * inserted after Android has moved the IME to another field or application.
 */
internal class KeyboardDictationInputGate {
    private var inputGeneration = 0L
    private var sessionInputGeneration: Long? = null

    fun beginInput() {
        inputGeneration += 1
    }

    fun invalidateInput() {
        inputGeneration += 1
    }

    fun bindSession() {
        sessionInputGeneration = inputGeneration
    }

    fun clearSession() {
        sessionInputGeneration = null
    }

    fun acceptsCallback(allowsDictation: Boolean): Boolean =
        allowsDictation && sessionInputGeneration == inputGeneration

    fun hasSession(): Boolean = sessionInputGeneration != null

    fun consumeResult(allowsDictation: Boolean): KeyboardDictationResultDisposition {
        val sessionGeneration = sessionInputGeneration
            ?: return KeyboardDictationResultDisposition.REJECTED
        val disposition = if (allowsDictation && sessionGeneration == inputGeneration) {
            KeyboardDictationResultDisposition.CURRENT_INPUT
        } else {
            KeyboardDictationResultDisposition.RECOVERABLE
        }
        sessionInputGeneration = null
        return disposition
    }

    companion object {
        fun shouldCancel(state: SpeechSessionState): Boolean =
            state == SpeechSessionState.PREPARING ||
                state == SpeechSessionState.LISTENING
    }
}
