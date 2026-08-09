package com.sohail.scribe.keyboard

import com.sohail.scribe.speech.SpeechSessionState

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
        sessionInputGeneration = null
    }

    fun invalidateInput() {
        inputGeneration += 1
        sessionInputGeneration = null
    }

    fun bindSession() {
        sessionInputGeneration = inputGeneration
    }

    fun clearSession() {
        sessionInputGeneration = null
    }

    fun acceptsCallback(allowsDictation: Boolean): Boolean =
        allowsDictation && sessionInputGeneration == inputGeneration

    fun consumeResult(allowsDictation: Boolean): Boolean {
        val accepted = acceptsCallback(allowsDictation)
        sessionInputGeneration = null
        return accepted
    }

    companion object {
        fun shouldCancel(state: SpeechSessionState): Boolean =
            state == SpeechSessionState.PREPARING ||
                state == SpeechSessionState.LISTENING ||
                state == SpeechSessionState.PROCESSING
    }
}
