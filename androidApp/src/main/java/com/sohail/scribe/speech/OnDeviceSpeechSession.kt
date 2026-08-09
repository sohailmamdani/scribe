package com.sohail.scribe.speech

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import com.sohail.scribe.core.TranscriptPolisher
import java.util.Locale

enum class SpeechSessionState { IDLE, PREPARING, LISTENING, PROCESSING, COMPLETED, FAILED }
enum class OnDeviceModelStatus { UNAVAILABLE, CHECKING, READY, DOWNLOADABLE, PENDING, DOWNLOADING, UNKNOWN }

object OnDeviceModelPolicy {
    fun status(
        installedLanguages: List<String>,
        pendingLanguages: List<String>,
        downloadableLanguages: List<String>,
    ): OnDeviceModelStatus = when {
        installedLanguages.isNotEmpty() -> OnDeviceModelStatus.READY
        pendingLanguages.isNotEmpty() -> OnDeviceModelStatus.PENDING
        downloadableLanguages.isNotEmpty() -> OnDeviceModelStatus.DOWNLOADABLE
        else -> OnDeviceModelStatus.UNKNOWN
    }
}

/** Selects Android's formatted hypothesis only when it preserves the raw words. */
internal object OnDeviceFormattingPolicy {
    fun bestResult(results: List<String>): String {
        val formatted = results.getOrNull(0).orEmpty()
        val raw = results.getOrNull(1).orEmpty()
        return when {
            formatted.isBlank() -> raw
            raw.isBlank() -> formatted
            TranscriptPolisher.isFaithfulRefinement(formatted, raw) -> formatted
            else -> raw
        }
    }
}

internal fun onDeviceRecognizerIntent(
    languageTag: String,
    sdkInt: Int = Build.VERSION.SDK_INT,
    enableFormatting: Boolean = true,
) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
    putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
    putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
    // One recognition result is enough. When API 33 formatting is honored,
    // Android still returns the documented formatted/raw hypothesis pair.
    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
    putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
    if (enableFormatting && sdkInt >= 33) {
        putExtra(
            RecognizerIntent.EXTRA_ENABLE_FORMATTING,
            RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY,
        )
        putExtra(RecognizerIntent.EXTRA_HIDE_PARTIAL_TRAILING_PUNCTUATION, true)
    }
}

internal class SpeechCallbackGate {
    private var generation = 0L

    fun begin(): Long {
        generation += 1
        return generation
    }

    fun invalidate() {
        generation += 1
    }

    fun accepts(token: Long): Boolean = token == generation
}

interface SpeechSessionListener {
    fun onStateChanged(state: SpeechSessionState, message: String) = Unit
    fun onAudioLevel(level: Float) = Unit
    fun onPartialResult(text: String) = Unit
    fun onFinalResult(text: String)
}

class OnDeviceSpeechSession(
    context: Context,
    private val listener: SpeechSessionListener,
    private val modelStatusListener: (OnDeviceModelStatus) -> Unit = {},
) : RecognitionListener {
    private val appContext = context.applicationContext
    private val callbackGate = SpeechCallbackGate()
    private var recognizer: SpeechRecognizer? = null
    private var receivedFinalResult = false

    val isAvailable: Boolean
        get() = SpeechRecognizer.isOnDeviceRecognitionAvailable(appContext)

    fun start(languageTag: String = Locale.getDefault().toLanguageTag()) {
        checkMainThread()
        if (!isAvailable) {
            listener.onStateChanged(
                SpeechSessionState.FAILED,
                "On-device speech recognition is not installed on this device.",
            )
            return
        }
        destroyRecognizer()
        receivedFinalResult = false
        listener.onStateChanged(SpeechSessionState.PREPARING, "Starting private on-device recognition…")
        val token = callbackGate.begin()
        try {
            val activeRecognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(appContext)
            recognizer = activeRecognizer
            activeRecognizer.setRecognitionListener(gatedRecognitionListener(token))
            activeRecognizer.startListening(onDeviceRecognizerIntent(languageTag))
        } catch (error: RuntimeException) {
            destroyRecognizer(token)
            listener.onStateChanged(SpeechSessionState.FAILED, startFailureMessage(error))
        }
    }

    fun stop() {
        checkMainThread()
        val activeRecognizer = recognizer ?: return
        try {
            listener.onStateChanged(SpeechSessionState.PROCESSING, "Finishing your words…")
            activeRecognizer.stopListening()
        } catch (_: RuntimeException) {
            destroyRecognizer()
            listener.onStateChanged(
                SpeechSessionState.FAILED,
                "Scribe couldn't stop private on-device recognition cleanly. Try again.",
            )
        }
    }

    fun cancel() {
        checkMainThread()
        try {
            recognizer?.cancel()
        } catch (_: RuntimeException) {
            // The recognizer may already have torn itself down after a terminal callback.
        }
        destroyRecognizer()
        listener.onStateChanged(SpeechSessionState.IDLE, "Ready")
    }

    fun requestModelDownload(languageTag: String = Locale.getDefault().toLanguageTag()): Boolean {
        checkMainThread()
        if (Build.VERSION.SDK_INT < 33 || !isAvailable) return false
        destroyRecognizer()
        val token = callbackGate.begin()
        try {
            val downloadRecognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(appContext)
            recognizer = downloadRecognizer
            downloadRecognizer.setRecognitionListener(gatedRecognitionListener(token))
            val intent = onDeviceRecognizerIntent(languageTag, enableFormatting = false)
            if (Build.VERSION.SDK_INT >= 34) {
                modelStatusListener(OnDeviceModelStatus.DOWNLOADING)
                listener.onStateChanged(SpeechSessionState.PREPARING, "Requesting the on-device language model…")
                downloadRecognizer.triggerModelDownload(
                    intent,
                    appContext.mainExecutor,
                    object : ModelDownloadListener {
                        override fun onProgress(completedPercent: Int) {
                            if (!callbackGate.accepts(token)) return
                            modelStatusListener(OnDeviceModelStatus.DOWNLOADING)
                            listener.onStateChanged(
                                SpeechSessionState.PREPARING,
                                "Downloading the on-device language model… ${completedPercent.coerceIn(0, 100)}%",
                            )
                        }

                        override fun onSuccess() {
                            if (!callbackGate.accepts(token)) return
                            destroyRecognizer(token)
                            modelStatusListener(OnDeviceModelStatus.READY)
                            listener.onStateChanged(SpeechSessionState.IDLE, "On-device language model ready")
                        }

                        override fun onScheduled() {
                            if (!callbackGate.accepts(token)) return
                            destroyRecognizer(token)
                            modelStatusListener(OnDeviceModelStatus.PENDING)
                            listener.onStateChanged(
                                SpeechSessionState.IDLE,
                                "On-device model download scheduled by Android",
                            )
                        }

                        override fun onError(error: Int) {
                            if (!callbackGate.accepts(token)) return
                            destroyRecognizer(token)
                            modelStatusListener(OnDeviceModelStatus.UNKNOWN)
                            listener.onStateChanged(SpeechSessionState.FAILED, errorMessage(error))
                        }
                    },
                )
            } else {
                downloadRecognizer.triggerModelDownload(intent)
                modelStatusListener(OnDeviceModelStatus.PENDING)
                listener.onStateChanged(
                    SpeechSessionState.IDLE,
                    "On-device model download requested in Android",
                )
            }
        } catch (_: RuntimeException) {
            destroyRecognizer(token)
            modelStatusListener(OnDeviceModelStatus.UNKNOWN)
            listener.onStateChanged(
                SpeechSessionState.FAILED,
                "Android couldn't start the on-device model download. Try again.",
            )
        }
        return true
    }

    fun checkModelSupport(languageTag: String = Locale.getDefault().toLanguageTag()) {
        checkMainThread()
        if (!isAvailable) {
            modelStatusListener(OnDeviceModelStatus.UNAVAILABLE)
            return
        }
        if (Build.VERSION.SDK_INT < 33) {
            modelStatusListener(OnDeviceModelStatus.UNKNOWN)
            return
        }
        destroyRecognizer()
        modelStatusListener(OnDeviceModelStatus.CHECKING)
        val token = callbackGate.begin()
        try {
            val supportRecognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(appContext)
            recognizer = supportRecognizer
            supportRecognizer.setRecognitionListener(gatedRecognitionListener(token))
            supportRecognizer.checkRecognitionSupport(
                onDeviceRecognizerIntent(languageTag, enableFormatting = false),
                appContext.mainExecutor,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(recognitionSupport: RecognitionSupport) {
                        if (!callbackGate.accepts(token)) return
                        val status = OnDeviceModelPolicy.status(
                            recognitionSupport.installedOnDeviceLanguages,
                            recognitionSupport.pendingOnDeviceLanguages,
                            recognitionSupport.supportedOnDeviceLanguages,
                        )
                        destroyRecognizer(token)
                        modelStatusListener(status)
                    }

                    override fun onError(error: Int) {
                        if (!callbackGate.accepts(token)) return
                        destroyRecognizer(token)
                        modelStatusListener(OnDeviceModelStatus.UNKNOWN)
                    }
                },
            )
        } catch (_: RuntimeException) {
            destroyRecognizer(token)
            modelStatusListener(OnDeviceModelStatus.UNKNOWN)
        }
    }

    fun destroy() {
        checkMainThread()
        destroyRecognizer()
    }

    override fun onReadyForSpeech(params: Bundle?) {
        listener.onStateChanged(SpeechSessionState.LISTENING, "Listening on device")
    }

    override fun onBeginningOfSpeech() {
        listener.onStateChanged(SpeechSessionState.LISTENING, "Listening on device")
    }

    override fun onRmsChanged(rmsdB: Float) {
        listener.onAudioLevel(((rmsdB + 2f) / 12f).coerceIn(0f, 1f))
    }

    override fun onBufferReceived(buffer: ByteArray?) = Unit

    override fun onEndOfSpeech() {
        listener.onStateChanged(SpeechSessionState.PROCESSING, "Finishing your words…")
    }

    override fun onError(error: Int) {
        if (receivedFinalResult && error == SpeechRecognizer.ERROR_CLIENT) return
        listener.onStateChanged(SpeechSessionState.FAILED, errorMessage(error))
        destroyRecognizer()
    }

    override fun onResults(results: Bundle?) {
        val text = bestResult(results)
        if (text.isBlank()) {
            listener.onStateChanged(SpeechSessionState.FAILED, "No speech was recognized. Try again.")
        } else {
            receivedFinalResult = true
            listener.onStateChanged(SpeechSessionState.COMPLETED, "Transcription complete")
            listener.onFinalResult(text)
        }
        destroyRecognizer()
    }

    override fun onPartialResults(partialResults: Bundle?) {
        bestResult(partialResults).takeIf(String::isNotBlank)?.let(listener::onPartialResult)
    }

    override fun onEvent(eventType: Int, params: Bundle?) = Unit

    private fun bestResult(bundle: Bundle?): String = bundle
        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
        ?.let(OnDeviceFormattingPolicy::bestResult)
        .orEmpty()

    private fun gatedRecognitionListener(token: Long) = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) = forward(token) {
            this@OnDeviceSpeechSession.onReadyForSpeech(params)
        }

        override fun onBeginningOfSpeech() = forward(token) {
            this@OnDeviceSpeechSession.onBeginningOfSpeech()
        }

        override fun onRmsChanged(rmsdB: Float) = forward(token) {
            this@OnDeviceSpeechSession.onRmsChanged(rmsdB)
        }

        override fun onBufferReceived(buffer: ByteArray?) = forward(token) {
            this@OnDeviceSpeechSession.onBufferReceived(buffer)
        }

        override fun onEndOfSpeech() = forward(token) {
            this@OnDeviceSpeechSession.onEndOfSpeech()
        }

        override fun onError(error: Int) = forward(token) {
            this@OnDeviceSpeechSession.onError(error)
        }

        override fun onResults(results: Bundle?) = forward(token) {
            this@OnDeviceSpeechSession.onResults(results)
        }

        override fun onPartialResults(partialResults: Bundle?) = forward(token) {
            this@OnDeviceSpeechSession.onPartialResults(partialResults)
        }

        override fun onEvent(eventType: Int, params: Bundle?) = forward(token) {
            this@OnDeviceSpeechSession.onEvent(eventType, params)
        }
    }

    private inline fun forward(token: Long, callback: () -> Unit) {
        if (callbackGate.accepts(token)) callback()
    }

    private fun destroyRecognizer(expectedToken: Long? = null) {
        if (expectedToken != null && !callbackGate.accepts(expectedToken)) return
        callbackGate.invalidate()
        val recognizerToDestroy = recognizer
        recognizer = null
        try {
            recognizerToDestroy?.destroy()
        } catch (_: RuntimeException) {
            // Destruction is best-effort; ownership has already been invalidated locally.
        }
    }

    private fun checkMainThread() {
        check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            "SpeechRecognizer must be used on the main thread"
        }
    }

    private fun startFailureMessage(error: RuntimeException): String =
        if (error is SecurityException) {
            "Allow microphone access in Scribe first."
        } else {
            "Scribe couldn't start private on-device recognition. Try again."
        }

    private fun errorMessage(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "Scribe couldn't access microphone audio."
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Allow microphone access in Scribe first."
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "This language is not supported on device."
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "Download the on-device language model in Scribe."
        SpeechRecognizer.ERROR_CANNOT_LISTEN_TO_DOWNLOAD_EVENTS ->
            "Android accepted the model request but cannot report download progress."
        SpeechRecognizer.ERROR_CANNOT_CHECK_SUPPORT ->
            "Android could not verify on-device recognition support."
        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
            "The installed on-device recognizer was unavailable. No audio was uploaded."
        SpeechRecognizer.ERROR_NO_MATCH -> "No speech was recognized. Try again."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "The on-device recognizer is busy. Try again."
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "The on-device recognizer stopped unexpectedly."
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "Scribe didn't hear any speech."
        else -> "Scribe couldn't finish recognition (error $error)."
    }
}
