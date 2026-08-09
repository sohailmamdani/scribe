package com.sohail.scribe.keyboard

import android.Manifest
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.core.content.ContextCompat
import com.sohail.scribe.core.DictationHistoryStore
import com.sohail.scribe.core.KeyboardEditingRules
import com.sohail.scribe.core.KeyboardPreferences
import com.sohail.scribe.core.ScribePreferences
import com.sohail.scribe.core.TranscriptPolisher
import com.sohail.scribe.speech.OnDeviceSpeechSession
import com.sohail.scribe.speech.SpeechSessionListener
import com.sohail.scribe.speech.SpeechSessionState
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class ScribeKeyboardService : InputMethodService(), KeyboardActionListener, SpeechSessionListener {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val suggestionGeneration = AtomicInteger()
    private lateinit var preferencesStore: ScribePreferences
    private lateinit var historyStore: DictationHistoryStore
    private lateinit var speechSession: OnDeviceSpeechSession
    private var keyboardView: ScribeKeyboardView? = null
    private var preferences = KeyboardPreferences()
    private var lexicon: KeyboardLexicon? = null
    private var swipeDecoder: SwipeWordDecoder? = null
    private var currentSuggestions: List<CorrectionCandidate> = emptyList()
    private var suggestionWord: String? = null
    private var sensitiveField = false
    private var lastCorrection: AppliedCorrection? = null
    private var speechMessage = "Dictate"
    private var partialTranscript = ""
    private var audioLevel = 0f
    private var speechState = SpeechSessionState.IDLE

    override fun onCreate() {
        super.onCreate()
        preferencesStore = ScribePreferences(this)
        historyStore = DictationHistoryStore(this)
        speechSession = OnDeviceSpeechSession(this, this)
        worker.execute {
            val loadedLexicon = KeyboardLexicon(this)
            val loadedSwipeDecoder = SwipeWordDecoder(this)
            mainHandler.post {
                lexicon = loadedLexicon
                swipeDecoder = loadedSwipeDecoder
                refreshSuggestions()
            }
        }
    }

    override fun onCreateInputView(): View = ScribeKeyboardView(this).also { view ->
        keyboardView = view
        view.listener = this
        view.updatePreferences(preferences)
        view.updateSpeechState(speechState, speechMessage, partialTranscript, audioLevel)
        view.updateAutomaticShift(KeyboardEditingRules.shouldCapitalize(contextBefore()))
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        preferences = preferencesStore.keyboard
        sensitiveField = info?.inputType?.let(::isSensitiveInputType) == true
        lastCorrection = null
        currentSuggestions = emptyList()
        suggestionWord = null
        keyboardView?.updatePreferences(preferences)
        keyboardView?.updateSuggestions(emptyList())
        keyboardView?.updateAutomaticShift(KeyboardEditingRules.shouldCapitalize(contextBefore()))
        refreshSuggestions()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        if (speechState == SpeechSessionState.LISTENING || speechState == SpeechSessionState.PREPARING) {
            speechSession.cancel()
        }
        super.onFinishInputView(finishingInput)
    }

    override fun onDestroy() {
        speechSession.destroy()
        worker.shutdownNow()
        super.onDestroy()
    }

    override fun onText(text: String, isLetter: Boolean) {
        if (text.isEmpty()) return
        if (!isLetter && text.singleOrNull() in listOf('.', ',', '?', '!', ';', ':')) {
            lastCorrection = applyAutomaticCorrection(text)
            currentInputConnection?.commitText(text, 1)
        } else {
            currentInputConnection?.commitText(text, 1)
            lastCorrection = null
        }
        updateAfterDocumentChange()
    }

    override fun onDelete() {
        val correction = lastCorrection
        val before = contextBefore()
        if (correction != null && before?.endsWith(correction.replacement + correction.delimiter) == true) {
            currentInputConnection?.deleteSurroundingTextInCodePoints(
                correction.replacement.codePointCount(0, correction.replacement.length) +
                    correction.delimiter.codePointCount(0, correction.delimiter.length),
                0,
            )
            currentInputConnection?.commitText(correction.original, 1)
            lastCorrection = null
        } else {
            currentInputConnection?.deleteSurroundingTextInCodePoints(1, 0)
        }
        updateAfterDocumentChange()
    }

    override fun onSpace() {
        val before = contextBefore()
        if (preferences.doubleSpacePeriodEnabled && KeyboardEditingRules.shouldReplaceDoubleSpace(before)) {
            currentInputConnection?.deleteSurroundingTextInCodePoints(1, 0)
            currentInputConnection?.commitText(". ", 1)
            lastCorrection = null
        } else {
            val correction = applyAutomaticCorrection(" ")
            currentInputConnection?.commitText(" ", 1)
            lastCorrection = correction
        }
        updateAfterDocumentChange()
    }

    override fun onEnter() {
        val options = currentInputEditorInfo?.imeOptions ?: EditorInfo.IME_ACTION_NONE
        val action = options and EditorInfo.IME_MASK_ACTION
        if (action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED) {
            currentInputConnection?.performEditorAction(action)
        } else {
            currentInputConnection?.commitText("\n", 1)
        }
        lastCorrection = null
        updateAfterDocumentChange()
    }

    override fun onMoveCursor(characters: Int) {
        val keyCode = if (characters < 0) KeyEvent.KEYCODE_DPAD_LEFT else KeyEvent.KEYCODE_DPAD_RIGHT
        repeat(kotlin.math.abs(characters)) {
            currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
            currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
        }
        lastCorrection = null
        refreshSuggestions()
    }

    override fun onSwipe(keys: List<Char>) {
        val decoder = swipeDecoder ?: return
        val generation = suggestionGeneration.incrementAndGet()
        worker.execute {
            val decoded = decoder.decode(keys)
            mainHandler.post {
                if (generation != suggestionGeneration.get() || decoded == null) return@post
                val before = contextBefore()
                if (!before.isNullOrEmpty() && !before.last().isWhitespace()) {
                    currentInputConnection?.commitText(" ", 1)
                }
                val word = if (KeyboardEditingRules.shouldCapitalize(contextBefore())) {
                    decoded.replaceFirstChar(Char::uppercase)
                } else {
                    decoded
                }
                currentInputConnection?.commitText("$word ", 1)
                lastCorrection = null
                updateAfterDocumentChange()
            }
        }
    }

    override fun onSuggestion(candidate: CorrectionCandidate) {
        val word = KeyboardEditingRules.currentWord(contextBefore()) ?: return
        currentInputConnection?.deleteSurroundingTextInCodePoints(word.codePointCount(0, word.length), 0)
        currentInputConnection?.commitText(candidate.text + " ", 1)
        lastCorrection = null
        updateAfterDocumentChange()
    }

    override fun onNextInputMethod() {
        switchToNextInputMethod(false)
    }

    override fun onToggleDictation() {
        when (speechState) {
            SpeechSessionState.LISTENING -> speechSession.stop()
            SpeechSessionState.PREPARING, SpeechSessionState.PROCESSING -> Unit
            else -> {
                when {
                    sensitiveField -> onStateChanged(
                        SpeechSessionState.FAILED,
                        "Dictation is unavailable in password fields.",
                    )
                    ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) !=
                        PackageManager.PERMISSION_GRANTED -> onStateChanged(
                        SpeechSessionState.FAILED,
                        "Open Scribe and allow microphone access first.",
                    )
                    else -> {
                        partialTranscript = ""
                        speechSession.start()
                    }
                }
            }
        }
    }

    override fun onCancelDictation() {
        speechSession.cancel()
    }

    override fun onStateChanged(state: SpeechSessionState, message: String) {
        speechState = state
        speechMessage = message
        if (state != SpeechSessionState.LISTENING) audioLevel = 0f
        if (state == SpeechSessionState.IDLE) partialTranscript = ""
        keyboardView?.updateSpeechState(state, message, partialTranscript, audioLevel)
    }

    override fun onAudioLevel(level: Float) {
        audioLevel = level
        keyboardView?.updateSpeechState(speechState, speechMessage, partialTranscript, audioLevel)
    }

    override fun onPartialResult(text: String) {
        partialTranscript = text
        keyboardView?.updateSpeechState(speechState, speechMessage, partialTranscript, audioLevel)
    }

    override fun onFinalResult(text: String) {
        val polished = TranscriptPolisher.polish(text)
        if (polished.isBlank()) {
            onStateChanged(SpeechSessionState.FAILED, "No speech was recognized. Try again.")
            return
        }
        val insertion = TranscriptPolisher.textForInsertion(polished, contextBefore(), contextAfter())
        currentInputConnection?.commitText(insertion, 1)
        historyStore.add(polished)
        partialTranscript = polished
        onStateChanged(SpeechSessionState.COMPLETED, "Inserted at the cursor")
        updateAfterDocumentChange()
        mainHandler.postDelayed({
            if (speechState == SpeechSessionState.COMPLETED) {
                partialTranscript = ""
                onStateChanged(SpeechSessionState.IDLE, "Dictate")
            }
        }, 1_800L)
    }

    private fun applyAutomaticCorrection(delimiter: String): AppliedCorrection? {
        if (!preferences.autocorrectionEnabled || sensitiveField) return null
        val original = KeyboardEditingRules.currentWord(contextBefore()) ?: return null
        val candidate = currentSuggestions.firstOrNull { it.automaticallyReplaces }
            ?.takeIf { suggestionWord.equals(original, ignoreCase = true) }
            ?: return null
        currentInputConnection?.deleteSurroundingTextInCodePoints(original.codePointCount(0, original.length), 0)
        currentInputConnection?.commitText(candidate.text, 1)
        return AppliedCorrection(original, candidate.text, delimiter)
    }

    private fun updateAfterDocumentChange() {
        keyboardView?.updateAutomaticShift(KeyboardEditingRules.shouldCapitalize(contextBefore()))
        refreshSuggestions()
    }

    private fun refreshSuggestions() {
        if (sensitiveField || !preferences.autocorrectionEnabled) {
            currentSuggestions = emptyList()
            suggestionWord = null
            keyboardView?.updateSuggestions(emptyList())
            return
        }
        val word = KeyboardEditingRules.currentWord(contextBefore())
        val loadedLexicon = lexicon
        if (word == null || loadedLexicon == null) {
            currentSuggestions = emptyList()
            suggestionWord = word
            keyboardView?.updateSuggestions(emptyList())
            return
        }
        val generation = suggestionGeneration.incrementAndGet()
        worker.execute {
            val candidates = loadedLexicon.corrections(word)
            mainHandler.post {
                if (generation != suggestionGeneration.get()) return@post
                val liveWord = KeyboardEditingRules.currentWord(contextBefore())
                if (!liveWord.equals(word, ignoreCase = true)) return@post
                suggestionWord = word
                currentSuggestions = candidates
                keyboardView?.updateSuggestions(candidates)
            }
        }
    }

    private fun contextBefore() = currentInputConnection?.getTextBeforeCursor(256, 0)
    private fun contextAfter() = currentInputConnection?.getTextAfterCursor(64, 0)

    private fun isSensitiveInputType(inputType: Int): Boolean {
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
            variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
    }

    private data class AppliedCorrection(
        val original: String,
        val replacement: String,
        val delimiter: String,
    )
}
