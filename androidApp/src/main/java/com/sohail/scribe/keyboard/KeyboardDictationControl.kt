package com.sohail.scribe.keyboard

import com.sohail.scribe.speech.SpeechSessionState

internal data class KeyboardDictationControl(
    val label: String,
    val enabled: Boolean,
)

internal object KeyboardDictationControlPolicy {
    fun control(state: SpeechSessionState): KeyboardDictationControl = when (state) {
        SpeechSessionState.IDLE,
        SpeechSessionState.COMPLETED,
        -> KeyboardDictationControl(label = "Dictate", enabled = true)
        SpeechSessionState.LISTENING ->
            KeyboardDictationControl(label = "Stop", enabled = true)
        SpeechSessionState.FAILED ->
            KeyboardDictationControl(label = "Retry", enabled = true)
        SpeechSessionState.PREPARING ->
            KeyboardDictationControl(label = "Starting", enabled = false)
        SpeechSessionState.PROCESSING ->
            KeyboardDictationControl(label = "Finishing", enabled = false)
    }
}
