package com.sohail.scribe.keyboard

import android.Manifest
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
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
    private var fieldProfile = KeyboardFieldProfile()
    private var lastCorrection: AppliedCorrection? = null
    private var lastDictationInsertion: String? = null
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
        view.updateFieldProfile(fieldProfile)
        view.updateSpeechState(speechState, speechMessage, partialTranscript, audioLevel)
        updateAutomaticShift()
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        preferences = preferencesStore.keyboard
        fieldProfile = KeyboardFieldProfile.from(
            inputType = info?.inputType ?: 0,
            imeOptions = info?.imeOptions ?: EditorInfo.IME_ACTION_NONE,
        )
        if (!fieldProfile.allowsDictation &&
            (speechState == SpeechSessionState.LISTENING || speechState == SpeechSessionState.PREPARING)
        ) {
            speechSession.cancel()
        }
        if (fieldProfile.sensitive) {
            speechState = SpeechSessionState.IDLE
            speechMessage = "Dictate"
            partialTranscript = ""
            audioLevel = 0f
        }
        lastCorrection = null
        lastDictationInsertion = null
        currentSuggestions = emptyList()
        suggestionWord = null
        keyboardView?.updatePreferences(preferences)
        keyboardView?.updateFieldProfile(fieldProfile)
        keyboardView?.updateSpeechState(speechState, speechMessage, partialTranscript, audioLevel)
        keyboardView?.updateSuggestions(emptyList())
        keyboardView?.updateUndoDictationAvailability(false)
        updateAutomaticShift()
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
        clearDictationUndo()
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
        clearDictationUndo()
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

    override fun onDeleteWord() {
        clearDictationUndo()
        val count = KeyboardEditingRules.deleteWordCodePointCount(contextBefore())
        currentInputConnection?.deleteSurroundingTextInCodePoints(count, 0)
        lastCorrection = null
        updateAfterDocumentChange()
    }

    override fun onSpace() {
        clearDictationUndo()
        val before = contextBefore()
        if (preferences.doubleSpacePeriodEnabled &&
            fieldProfile.layout == KeyboardFieldLayout.TEXT &&
            KeyboardEditingRules.shouldReplaceDoubleSpace(before)
        ) {
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
        clearDictationUndo()
        val options = currentInputEditorInfo?.imeOptions ?: EditorInfo.IME_ACTION_NONE
        val action = options and EditorInfo.IME_MASK_ACTION
        if (fieldProfile.returnAction != KeyboardReturnAction.RETURN &&
            action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED
        ) {
            currentInputConnection?.performEditorAction(action)
        } else {
            currentInputConnection?.commitText("\n", 1)
        }
        lastCorrection = null
        updateAfterDocumentChange()
    }

    override fun onMoveCursor(characters: Int) {
        clearDictationUndo()
        val keyCode = if (characters < 0) KeyEvent.KEYCODE_DPAD_LEFT else KeyEvent.KEYCODE_DPAD_RIGHT
        repeat(kotlin.math.abs(characters)) {
            currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
            currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
        }
        lastCorrection = null
        refreshSuggestions()
    }

    override fun onSwipe(keys: List<Char>) {
        clearDictationUndo()
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
        clearDictationUndo()
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
                    fieldProfile.sensitive -> onStateChanged(
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
                        clearDictationUndo()
                        speechSession.start()
                    }
                }
            }
        }
    }

    override fun onCancelDictation() {
        speechSession.cancel()
    }

    override fun onUndoDictation() {
        val insertion = lastDictationInsertion ?: return
        val before = currentInputConnection?.getTextBeforeCursor(insertion.length, 0)?.toString()
        if (before?.endsWith(insertion) == true) {
            currentInputConnection?.deleteSurroundingTextInCodePoints(
                insertion.codePointCount(0, insertion.length),
                0,
            )
            lastCorrection = null
            clearDictationUndo()
            updateAfterDocumentChange()
        } else {
            clearDictationUndo()
        }
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
        lastDictationInsertion = insertion
        keyboardView?.updateUndoDictationAvailability(true)
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
        if (!preferences.autocorrectionEnabled || !fieldProfile.allowsSuggestions) return null
        val original = KeyboardEditingRules.currentWord(contextBefore()) ?: return null
        val candidate = currentSuggestions.firstOrNull { it.automaticallyReplaces }
            ?.takeIf { suggestionWord.equals(original, ignoreCase = true) }
            ?: return null
        currentInputConnection?.deleteSurroundingTextInCodePoints(original.codePointCount(0, original.length), 0)
        currentInputConnection?.commitText(candidate.text, 1)
        return AppliedCorrection(original, candidate.text, delimiter)
    }

    private fun updateAfterDocumentChange() {
        updateAutomaticShift()
        refreshSuggestions()
    }

    private fun updateAutomaticShift() {
        val shouldShift = when (fieldProfile.capitalization) {
            KeyboardCapitalization.NONE -> false
            KeyboardCapitalization.WORDS -> KeyboardEditingRules.shouldCapitalizeWord(contextBefore())
            KeyboardCapitalization.SENTENCES -> KeyboardEditingRules.shouldCapitalize(contextBefore())
            KeyboardCapitalization.ALL_CHARACTERS -> true
        }
        keyboardView?.updateAutomaticShift(
            shouldShift = shouldShift,
            lockAutomatically = fieldProfile.capitalization == KeyboardCapitalization.ALL_CHARACTERS,
        )
    }

    private fun clearDictationUndo() {
        if (lastDictationInsertion == null) return
        lastDictationInsertion = null
        keyboardView?.updateUndoDictationAvailability(false)
    }

    private fun refreshSuggestions() {
        if (!fieldProfile.allowsSuggestions || !preferences.autocorrectionEnabled) {
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

    private data class AppliedCorrection(
        val original: String,
        val replacement: String,
        val delimiter: String,
    )
}
