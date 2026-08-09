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
        recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(appContext).also {
            it.setRecognitionListener(this)
            it.startListening(recognizerIntent(languageTag))
        }
    }

    fun stop() {
        checkMainThread()
        listener.onStateChanged(SpeechSessionState.PROCESSING, "Finishing your words…")
        recognizer?.stopListening()
    }

    fun cancel() {
        checkMainThread()
        recognizer?.cancel()
        destroyRecognizer()
        listener.onStateChanged(SpeechSessionState.IDLE, "Ready")
    }

    fun requestModelDownload(languageTag: String = Locale.getDefault().toLanguageTag()): Boolean {
        checkMainThread()
        if (Build.VERSION.SDK_INT < 33 || !isAvailable) return false
        destroyRecognizer()
        val downloadRecognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(appContext).also {
            it.setRecognitionListener(this)
        }
        recognizer = downloadRecognizer
        val intent = recognizerIntent(languageTag)
        if (Build.VERSION.SDK_INT >= 34) {
            modelStatusListener(OnDeviceModelStatus.DOWNLOADING)
            listener.onStateChanged(SpeechSessionState.PREPARING, "Requesting the on-device language model…")
            downloadRecognizer.triggerModelDownload(
                intent,
                appContext.mainExecutor,
                object : ModelDownloadListener {
                    override fun onProgress(completedPercent: Int) {
                        modelStatusListener(OnDeviceModelStatus.DOWNLOADING)
                        listener.onStateChanged(
                            SpeechSessionState.PREPARING,
                            "Downloading the on-device language model… ${completedPercent.coerceIn(0, 100)}%",
                        )
                    }

                    override fun onSuccess() {
                        destroyRecognizer()
                        modelStatusListener(OnDeviceModelStatus.READY)
                        listener.onStateChanged(SpeechSessionState.IDLE, "On-device language model ready")
                    }

                    override fun onScheduled() {
                        destroyRecognizer()
                        modelStatusListener(OnDeviceModelStatus.PENDING)
                        listener.onStateChanged(
                            SpeechSessionState.IDLE,
                            "On-device model download scheduled by Android",
                        )
                    }

                    override fun onError(error: Int) {
                        destroyRecognizer()
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
        val supportRecognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(appContext)
        recognizer = supportRecognizer
        supportRecognizer.setRecognitionListener(this)
        supportRecognizer.checkRecognitionSupport(
            recognizerIntent(languageTag),
            appContext.mainExecutor,
            object : RecognitionSupportCallback {
                override fun onSupportResult(recognitionSupport: RecognitionSupport) {
                    val status = OnDeviceModelPolicy.status(
                        recognitionSupport.installedOnDeviceLanguages,
                        recognitionSupport.pendingOnDeviceLanguages,
                        recognitionSupport.supportedOnDeviceLanguages,
                    )
                    destroyRecognizer()
                    modelStatusListener(status)
                }

                override fun onError(error: Int) {
                    destroyRecognizer()
                    modelStatusListener(OnDeviceModelStatus.UNKNOWN)
                }
            },
        )
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

    private fun recognizerIntent(languageTag: String) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
    }

    private fun bestResult(bundle: Bundle?): String = bundle
        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
        ?.firstOrNull()
        .orEmpty()

    private fun destroyRecognizer() {
        recognizer?.destroy()
        recognizer = null
    }

    private fun checkMainThread() {
        check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            "SpeechRecognizer must be used on the main thread"
        }
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
