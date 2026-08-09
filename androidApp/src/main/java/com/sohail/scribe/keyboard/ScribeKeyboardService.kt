package com.sohail.scribe.keyboard

import android.Manifest
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
    private lateinit var correctionLearning: KeyboardCorrectionLearningStore
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
    private val tapEvidence = mutableListOf<KeyboardTapEvidence?>()
    private var lastSpaceTapMillis: Long? = null
    private var speechMessage = "Dictate"
    private var partialTranscript = ""
    private var audioLevel = 0f
    private var speechState = SpeechSessionState.IDLE
    private var selectionStart = -1
    private var selectionEnd = -1
    private var localMutationGraceDeadlineMillis = 0L

    override fun onCreate() {
        super.onCreate()
        preferencesStore = ScribePreferences(this)
        historyStore = DictationHistoryStore(this)
        correctionLearning = KeyboardCorrectionLearningStore(this)
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
        view.updateOffersInputModeSwitch(shouldOfferSwitchingToNextInputMethod())
        view.updateSpeechState(speechState, speechMessage, partialTranscript, audioLevel)
        view.updateAutocorrectionUndoOriginal(lastCorrection?.original)
        updateAutomaticShift()
    }

    /** Keep the custom keyboard visible in landscape instead of Android's extract editor. */
    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        preferences = preferencesStore.keyboard
        fieldProfile = KeyboardFieldProfile.from(
            inputType = info?.inputType ?: 0,
            imeOptions = info?.imeOptions ?: EditorInfo.IME_ACTION_NONE,
        )
        selectionStart = info?.initialSelStart ?: -1
        selectionEnd = info?.initialSelEnd ?: -1
        markLocalMutation()
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
        tapEvidence.clear()
        lastSpaceTapMillis = null
        currentSuggestions = emptyList()
        suggestionWord = null
        keyboardView?.updatePreferences(preferences)
        keyboardView?.updateFieldProfile(fieldProfile)
        keyboardView?.updateOffersInputModeSwitch(shouldOfferSwitchingToNextInputMethod())
        keyboardView?.updateSpeechState(speechState, speechMessage, partialTranscript, audioLevel)
        keyboardView?.updateSuggestions(emptyList())
        keyboardView?.updateUndoDictationAvailability(false)
        keyboardView?.updateAutocorrectionUndoOriginal(null)
        updateAutomaticShift()
        refreshSuggestions()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        acceptPendingCorrection()
        if (speechState == SpeechSessionState.LISTENING || speechState == SpeechSessionState.PREPARING) {
            speechSession.cancel()
        }
        super.onFinishInputView(finishingInput)
    }

    override fun onUpdateSelection(
        oldSelStart: Int,
        oldSelEnd: Int,
        newSelStart: Int,
        newSelEnd: Int,
        candidatesStart: Int,
        candidatesEnd: Int,
    ) {
        super.onUpdateSelection(
            oldSelStart,
            oldSelEnd,
            newSelStart,
            newSelEnd,
            candidatesStart,
            candidatesEnd,
        )
        selectionStart = newSelStart
        selectionEnd = newSelEnd
        if (SystemClock.uptimeMillis() > localMutationGraceDeadlineMillis) {
            // The host, rather than this keyboard, moved the caret. Any tap
            // geometry and double-space timing now describe the wrong word.
            tapEvidence.clear()
            lastSpaceTapMillis = null
        }
        reconcileUndoAffordances()
        updateAfterDocumentChange()
    }

    override fun onDestroy() {
        speechSession.destroy()
        worker.shutdownNow()
        super.onDestroy()
    }

    override fun onText(text: String, isLetter: Boolean, evidence: KeyboardTapEvidence?) {
        if (text.isEmpty()) return
        markLocalMutation()
        clearDictationUndo()
        if (hasActiveSelection()) {
            lastCorrection = null
            updateAutocorrectionUndoAvailability()
        } else {
            acceptPendingCorrection()
        }
        lastSpaceTapMillis = null
        if (hasActiveSelection()) tapEvidence.clear()
        if (isLetter) tapEvidence += evidence else tapEvidence.clear()
        if (!isLetter && text.singleOrNull() in listOf('.', ',', '?', '!', ';', ':')) {
            lastCorrection = applyAutomaticCorrection(text)
            currentInputConnection?.commitText(text, 1)
            updateAutocorrectionUndoAvailability()
        } else {
            currentInputConnection?.commitText(text, 1)
        }
        updateAfterDocumentChange()
    }

    override fun onDelete() {
        clearDictationUndo()
        lastSpaceTapMillis = null
        if (hasActiveSelection()) {
            markLocalMutation()
            tapEvidence.clear()
            lastCorrection = null
            updateAutocorrectionUndoAvailability()
            if (KeyboardSelectionEditing.deleteSelection(currentInputConnection, selectionStart, selectionEnd)) {
                val collapsed = minOf(selectionStart, selectionEnd)
                selectionStart = collapsed
                selectionEnd = collapsed
            }
            updateAfterDocumentChange()
            return
        }
        markLocalMutation()
        if (undoLastAutocorrection()) {
            tapEvidence.clear()
        } else {
            acceptPendingCorrection()
            if (tapEvidence.isNotEmpty()) tapEvidence.removeAt(tapEvidence.lastIndex)
            currentInputConnection?.deleteSurroundingTextInCodePoints(1, 0)
        }
        updateAfterDocumentChange()
    }

    override fun onDeleteWord() {
        clearDictationUndo()
        tapEvidence.clear()
        lastSpaceTapMillis = null
        if (hasActiveSelection()) {
            markLocalMutation()
            lastCorrection = null
            updateAutocorrectionUndoAvailability()
            if (KeyboardSelectionEditing.deleteSelection(currentInputConnection, selectionStart, selectionEnd)) {
                val collapsed = minOf(selectionStart, selectionEnd)
                selectionStart = collapsed
                selectionEnd = collapsed
            }
            updateAfterDocumentChange()
            return
        }
        acceptPendingCorrection()
        markLocalMutation()
        val count = KeyboardEditingRules.deleteWordCodePointCount(contextBefore())
        currentInputConnection?.deleteSurroundingTextInCodePoints(count, 0)
        lastCorrection = null
        updateAfterDocumentChange()
    }

    override fun onSpace() {
        clearDictationUndo()
        if (hasActiveSelection()) {
            markLocalMutation()
            lastCorrection = null
            updateAutocorrectionUndoAvailability()
            tapEvidence.clear()
            currentInputConnection?.commitText(" ", 1)
            lastSpaceTapMillis = System.currentTimeMillis()
            updateAfterDocumentChange()
            return
        }
        acceptPendingCorrection()
        markLocalMutation()
        val before = contextBefore()
        val now = System.currentTimeMillis()
        val elapsed = lastSpaceTapMillis?.let { now - it }
        if (preferences.doubleSpacePeriodEnabled &&
            fieldProfile.layout == KeyboardFieldLayout.TEXT &&
            KeyboardEditingRules.shouldReplaceDoubleSpace(before, elapsed)
        ) {
            currentInputConnection?.deleteSurroundingTextInCodePoints(1, 0)
            currentInputConnection?.commitText(". ", 1)
            lastCorrection = null
            lastSpaceTapMillis = null
        } else {
            val correction = applyAutomaticCorrection(" ")
            currentInputConnection?.commitText(" ", 1)
            lastCorrection = correction
            updateAutocorrectionUndoAvailability()
            lastSpaceTapMillis = now
        }
        tapEvidence.clear()
        updateAfterDocumentChange()
    }

    override fun onEnter() {
        clearDictationUndo()
        acceptPendingCorrection()
        tapEvidence.clear()
        lastSpaceTapMillis = null
        markLocalMutation()
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
        acceptPendingCorrection()
        tapEvidence.clear()
        lastSpaceTapMillis = null
        markLocalMutation()
        val movedSelection = KeyboardCursorEditing.moveCollapsedSelection(
            connection = currentInputConnection,
            selectionStart = selectionStart,
            selectionEnd = selectionEnd,
            characters = characters,
        )
        if (movedSelection != null) {
            selectionStart = movedSelection
            selectionEnd = movedSelection
        } else {
            val keyCode = if (characters < 0) KeyEvent.KEYCODE_DPAD_LEFT else KeyEvent.KEYCODE_DPAD_RIGHT
            repeat(kotlin.math.abs(characters)) {
                currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
                currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
            }
        }
        lastCorrection = null
        refreshSuggestions()
    }

    override fun onSwipe(keys: List<Char>, capitalize: Boolean) {
        clearDictationUndo()
        acceptPendingCorrection()
        tapEvidence.clear()
        lastSpaceTapMillis = null
        val decoder = swipeDecoder ?: return
        val generation = suggestionGeneration.incrementAndGet()
        worker.execute {
            val decoded = decoder.decode(keys)
            mainHandler.post {
                if (generation != suggestionGeneration.get() || decoded == null) return@post
                markLocalMutation()
                val insertion = KeyboardSwipeInsertion.text(decoded, contextBefore(), capitalize)
                currentInputConnection?.commitText(insertion, 1)
                lastCorrection = null
                updateAfterDocumentChange()
            }
        }
    }

    override fun onSuggestion(candidate: CorrectionCandidate) {
        if (hasActiveSelection()) return
        clearDictationUndo()
        acceptPendingCorrection()
        lastSpaceTapMillis = null
        markLocalMutation()
        val word = KeyboardEditingRules.currentWord(contextBefore()) ?: return
        currentInputConnection?.deleteSurroundingTextInCodePoints(word.codePointCount(0, word.length), 0)
        currentInputConnection?.commitText(candidate.text + " ", 1)
        recordAcceptedCorrection(word, candidate.text)
        tapEvidence.clear()
        lastCorrection = AppliedCorrection(word, candidate.text, " ")
        updateAutocorrectionUndoAvailability()
        updateAfterDocumentChange()
    }

    override fun onUndoAutocorrection() {
        clearDictationUndo()
        lastSpaceTapMillis = null
        tapEvidence.clear()
        markLocalMutation()
        undoLastAutocorrection()
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
                        acceptPendingCorrection()
                        tapEvidence.clear()
                        lastSpaceTapMillis = null
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
            markLocalMutation()
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
        markLocalMutation()
        currentInputConnection?.commitText(insertion, 1)
        tapEvidence.clear()
        lastSpaceTapMillis = null
        lastDictationInsertion = insertion
        keyboardView?.updateUndoDictationAvailability(true)
        if (fieldProfile.allowsPersonalizedLearning) historyStore.add(polished)
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
        if (hasActiveSelection() || !preferences.autocorrectionEnabled || !fieldProfile.allowsSuggestions) {
            return null
        }
        val original = KeyboardEditingRules.currentWord(contextBefore()) ?: return null
        val candidate = currentSuggestions.firstOrNull { it.automaticallyReplaces }
            ?.takeIf { suggestionWord.equals(original, ignoreCase = true) }
            ?: return null
        currentInputConnection?.deleteSurroundingTextInCodePoints(original.codePointCount(0, original.length), 0)
        currentInputConnection?.commitText(candidate.text, 1)
        tapEvidence.clear()
        return AppliedCorrection(original, candidate.text, delimiter)
    }

    private fun updateAfterDocumentChange() {
        updateAutomaticShift()
        refreshSuggestions()
    }

    private fun updateAutomaticShift() {
        keyboardView?.updateAutomaticShift(
            shouldShift = automaticShiftRequired(),
            lockAutomatically = fieldProfile.capitalization == KeyboardCapitalization.ALL_CHARACTERS,
        )
    }

    private fun automaticShiftRequired(): Boolean = when (fieldProfile.capitalization) {
            KeyboardCapitalization.NONE -> false
            KeyboardCapitalization.WORDS -> KeyboardEditingRules.shouldCapitalizeWord(contextBefore())
            KeyboardCapitalization.SENTENCES -> KeyboardEditingRules.shouldCapitalize(contextBefore())
            KeyboardCapitalization.ALL_CHARACTERS -> true
        }

    private fun clearDictationUndo() {
        if (lastDictationInsertion == null) return
        lastDictationInsertion = null
        keyboardView?.updateUndoDictationAvailability(false)
    }

    private fun acceptPendingCorrection() {
        val correction = lastCorrection ?: return
        recordAcceptedCorrection(correction.original, correction.replacement)
        lastCorrection = null
        updateAutocorrectionUndoAvailability()
    }

    private fun undoLastAutocorrection(): Boolean {
        val correction = lastCorrection ?: return false
        val suffix = correction.replacement + correction.delimiter
        val before = contextBefore()
        if (before?.endsWith(suffix) != true) {
            lastCorrection = null
            updateAutocorrectionUndoAvailability()
            return false
        }
        currentInputConnection?.deleteSurroundingTextInCodePoints(
            suffix.codePointCount(0, suffix.length),
            0,
        )
        currentInputConnection?.commitText(correction.original + correction.delimiter, 1)
        recordRejectedCorrection(correction.original, correction.replacement)
        lastCorrection = null
        updateAutocorrectionUndoAvailability()
        return true
    }

    private fun updateAutocorrectionUndoAvailability() {
        keyboardView?.updateAutocorrectionUndoOriginal(lastCorrection?.original)
    }

    private fun recordAcceptedCorrection(original: String, replacement: String) {
        if (fieldProfile.allowsPersonalizedLearning) {
            correctionLearning.recordAccepted(original, replacement)
        }
    }

    private fun recordRejectedCorrection(original: String, replacement: String) {
        if (fieldProfile.allowsPersonalizedLearning) {
            correctionLearning.recordRejected(original, replacement)
        }
    }

    private fun reconcileUndoAffordances() {
        if (hasActiveSelection()) {
            lastCorrection = null
            clearDictationUndo()
            updateAutocorrectionUndoAvailability()
            return
        }
        val before = contextBefore()
        lastCorrection?.let { correction ->
            if (before?.endsWith(correction.replacement + correction.delimiter) != true) {
                lastCorrection = null
                updateAutocorrectionUndoAvailability()
            }
        }
        lastDictationInsertion?.let { insertion ->
            if (before?.endsWith(insertion) != true) clearDictationUndo()
        }
    }

    private fun refreshSuggestions() {
        if (hasActiveSelection() || !fieldProfile.allowsSuggestions || !preferences.autocorrectionEnabled) {
            suggestionGeneration.incrementAndGet()
            currentSuggestions = emptyList()
            suggestionWord = null
            keyboardView?.updateSuggestions(emptyList())
            return
        }
        val word = KeyboardEditingRules.currentWord(contextBefore())
        val loadedLexicon = lexicon
        if (word == null || loadedLexicon == null) {
            suggestionGeneration.incrementAndGet()
            currentSuggestions = emptyList()
            suggestionWord = word
            keyboardView?.updateSuggestions(emptyList())
            return
        }
        val generation = suggestionGeneration.incrementAndGet()
        val contextSnapshot = contextBefore()?.toString()
        val evidenceSnapshot = tapEvidence.takeLast(word.length).let { suffix ->
            List<KeyboardTapEvidence?>(word.length - suffix.size) { null } + suffix
        }
        val protectedSnapshot = correctionLearning.protectedWordsSnapshot()
        val acceptedSnapshot = correctionLearning.acceptedCountsSnapshot()
        worker.execute {
            val candidates = loadedLexicon.corrections(
                original = word,
                contextBefore = contextSnapshot,
                protectedWords = protectedSnapshot,
                acceptedCounts = acceptedSnapshot,
                evidence = evidenceSnapshot,
            )
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

    private fun hasActiveSelection(): Boolean =
        KeyboardSelectionEditing.hasSelection(selectionStart, selectionEnd)

    private fun markLocalMutation() {
        localMutationGraceDeadlineMillis = SystemClock.uptimeMillis() + LOCAL_MUTATION_GRACE_MILLIS
    }

    private data class AppliedCorrection(
        val original: String,
        val replacement: String,
        val delimiter: String,
    )

    companion object {
        private const val LOCAL_MUTATION_GRACE_MILLIS = 250L
    }
}
