package com.sohail.scribe.keyboard

import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.media.AudioManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityEvent
import androidx.core.view.ViewCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.customview.widget.ExploreByTouchHelper
import com.sohail.scribe.core.KeyboardEditingRules
import com.sohail.scribe.core.KeyboardPreferences
import com.sohail.scribe.speech.SpeechSessionState
import kotlin.math.hypot

interface KeyboardActionListener {
    fun onText(text: String, isLetter: Boolean = false, evidence: KeyboardTapEvidence? = null)
    fun onDelete()
    fun onDeleteWord()
    fun onSpace()
    fun onEnter()
    fun onMoveCursor(characters: Int)
    fun onSwipe(keys: List<Char>, capitalize: Boolean)
    fun onSuggestion(candidate: CorrectionCandidate)
    fun onUndoAutocorrection()
    fun onNextInputMethod()
    fun onToggleDictation()
    fun onCancelDictation()
    fun onUndoDictation()
}

private enum class KeyboardPage { LETTERS, NUMBERS, SYMBOLS, NUMBER_PAD, PHONE_PAD }
private enum class ShiftState { OFF, ONCE, LOCKED }
private enum class KeyKind {
    TEXT, SHIFT, DELETE, SPACE, ENTER, MODE, MORE_SYMBOLS, NEXT_INPUT, MICROPHONE, CANCEL,
    UNDO_DICTATION, UNDO_AUTOCORRECTION, SUGGESTION
}

private data class KeySpec(
    val id: String,
    val label: String,
    val output: String? = null,
    val kind: KeyKind = KeyKind.TEXT,
    val rect: RectF = RectF(),
    val alternate: String? = null,
    val candidate: CorrectionCandidate? = null,
)

class ScribeKeyboardView(context: Context) : View(context) {
    var listener: KeyboardActionListener? = null

    private val density = resources.displayMetrics.density
    private val handler = Handler(Looper.getMainLooper())
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create("sans", Typeface.NORMAL)
    }
    private val boldPaint = Paint(paint).apply { typeface = Typeface.create("sans", Typeface.BOLD) }
    private val trailPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(130, 84, 79, 210)
        style = Paint.Style.STROKE
        strokeWidth = dp(8f)
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val keys = mutableListOf<KeySpec>()
    private var hitRegions: Map<String, KeyboardHitRect> = emptyMap()
    private var keyAreaTop = 0f
    private val swipePoints = mutableListOf<Pair<Float, Float>>()
    private val swipeKeys = mutableListOf<Char>()
    private var page = KeyboardPage.LETTERS
    private var shift = ShiftState.ONCE
    private var lastShiftTapMillis = 0L
    private var preferences = KeyboardPreferences()
    private var fieldProfile = KeyboardFieldProfile()
    private var suggestions: List<CorrectionCandidate> = emptyList()
    private var undoDictationAvailable = false
    private var autocorrectionUndoOriginal: String? = null
    private var speechState = SpeechSessionState.IDLE
    private var speechMessage = "Dictate"
    private var partialTranscript = ""
    private var audioLevel = 0f
    private var currentKey: KeySpec? = null
    private var downX = 0f
    private var downY = 0f
    private var alternateArmed = false
    private var alternateSelectionActive = false
    private var deleteRepeated = false
    private var deleteRepeatCount = 0
    private var isSwiping = false
    private var spaceCursorMode = false
    private var cursorSteps = 0
    private var punctuationPopupVisible = false
    private var selectedPunctuation: String? = null
    private var offersInputModeSwitch = true
    private val accessibilityHelper = object : ExploreByTouchHelper(this) {
        override fun getVirtualViewAt(x: Float, y: Float): Int {
            val resolved = keyAt(x, y) ?: return INVALID_ID
            return keys.indexOfFirst { it.id == resolved.id }.takeIf { it >= 0 } ?: INVALID_ID
        }

        override fun getVisibleVirtualViews(virtualViewIds: MutableList<Int>) {
            keys.indices.forEach(virtualViewIds::add)
        }

        @Suppress("DEPRECATION") // ExploreByTouchHelper virtual children require parent-relative bounds.
        override fun onPopulateNodeForVirtualView(
            virtualViewId: Int,
            node: AccessibilityNodeInfoCompat,
        ) {
            val key = keys.getOrNull(virtualViewId) ?: return
            node.className = "android.widget.Button"
            node.contentDescription = accessibleLabel(key)
            node.hintText = when {
                key.kind == KeyKind.SPACE -> "Touch and hold, then drag to move the cursor"
                key.id == "period" && preferences.alternateSymbolsEnabled ->
                    "Long press, then slide for more punctuation"
                preferences.alternateSymbolsEnabled && key.alternate != null ->
                    "Long press for ${KeyboardAccessibilityLabels.labelFor("alternate", key.alternate)}"
                else -> null
            }
            val accessibleBounds = hitRegions[key.id]
            node.setBoundsInParent(
                Rect(
                    (accessibleBounds?.left ?: key.rect.left).toInt(),
                    (accessibleBounds?.top ?: key.rect.top).toInt(),
                    (accessibleBounds?.right ?: key.rect.right).toInt(),
                    (accessibleBounds?.bottom ?: key.rect.bottom).toInt(),
                ),
            )
            node.isClickable = true
            node.isEnabled = true
            node.addAction(AccessibilityNodeInfoCompat.ACTION_CLICK)
            if (preferences.alternateSymbolsEnabled && key.alternate != null) {
                node.isLongClickable = true
                node.addAction(AccessibilityNodeInfoCompat.ACTION_LONG_CLICK)
            }
        }

        override fun onPerformActionForVirtualView(
            virtualViewId: Int,
            action: Int,
            arguments: Bundle?,
        ): Boolean {
            val key = keys.getOrNull(virtualViewId) ?: return false
            return when (action) {
                AccessibilityNodeInfoCompat.ACTION_CLICK -> {
                    commitKey(key)
                    sendEventForVirtualView(virtualViewId, AccessibilityEvent.TYPE_VIEW_CLICKED)
                    true
                }
                AccessibilityNodeInfoCompat.ACTION_LONG_CLICK -> key.alternate
                    ?.takeIf { preferences.alternateSymbolsEnabled }
                    ?.let {
                    commitAlternate(key)
                    sendEventForVirtualView(virtualViewId, AccessibilityEvent.TYPE_VIEW_LONG_CLICKED)
                    true
                } ?: false
                else -> false
            }
        }
    }

    private val alternateRunnable = Runnable {
        val key = currentKey ?: return@Runnable
        if (preferences.alternateSymbolsEnabled && key.alternate != null && !isSwiping) {
            alternateArmed = true
            alternateSelectionActive = true
            feedback(HapticFeedbackConstants.LONG_PRESS)
            invalidate()
        }
    }
    private val deleteRepeatRunnable = object : Runnable {
        override fun run() {
            if (currentKey?.kind != KeyKind.DELETE) return
            deleteRepeated = true
            if (deleteRepeatCount < 18) {
                listener?.onDelete()
                deleteRepeatCount += 1
            } else {
                listener?.onDeleteWord()
            }
            feedback(HapticFeedbackConstants.KEYBOARD_TAP)
            val nextDelay = when {
                deleteRepeatCount >= 18 -> 280L
                deleteRepeatCount > 8 -> 80L
                else -> 110L
            }
            handler.postDelayed(this, nextDelay)
        }
    }
    private val punctuationRunnable = Runnable {
        if (preferences.alternateSymbolsEnabled && currentKey?.id == "period") {
            punctuationPopupVisible = true
            selectedPunctuation = "."
            feedback(HapticFeedbackConstants.LONG_PRESS)
            invalidate()
        }
    }
    private val spaceCursorRunnable = Runnable {
        if (currentKey?.kind == KeyKind.SPACE) {
            spaceCursorMode = true
            cursorSteps = 0
            feedback(HapticFeedbackConstants.LONG_PRESS)
            invalidate()
        }
    }

    init {
        isFocusable = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        ViewCompat.setAccessibilityDelegate(this, accessibilityHelper)
    }

    fun updatePreferences(value: KeyboardPreferences) {
        preferences = value.normalized()
        invalidate()
    }

    fun updateFieldProfile(value: KeyboardFieldProfile) {
        fieldProfile = value
        page = when (value.layout) {
            KeyboardFieldLayout.NUMBER,
            KeyboardFieldLayout.DATE,
            KeyboardFieldLayout.TIME,
            KeyboardFieldLayout.DATETIME,
            -> KeyboardPage.NUMBER_PAD
            KeyboardFieldLayout.PHONE -> KeyboardPage.PHONE_PAD
            else -> KeyboardPage.LETTERS
        }
        shift = if (value.capitalization == KeyboardCapitalization.ALL_CHARACTERS) {
            ShiftState.LOCKED
        } else {
            ShiftState.OFF
        }
        rebuildKeys(width, height)
        accessibilityHelper.invalidateRoot()
        invalidate()
    }

    fun updateOffersInputModeSwitch(offersSwitch: Boolean) {
        offersInputModeSwitch = offersSwitch
        rebuildKeys(width, height)
        invalidate()
    }

    fun updateSuggestions(value: List<CorrectionCandidate>) {
        suggestions = value
        rebuildKeys(width, height)
        invalidate()
    }

    fun updateUndoDictationAvailability(available: Boolean) {
        undoDictationAvailable = available
        rebuildKeys(width, height)
        invalidate()
    }

    fun updateAutocorrectionUndoOriginal(original: String?) {
        autocorrectionUndoOriginal = original
        rebuildKeys(width, height)
        invalidate()
    }

    fun updateAutomaticShift(shouldShift: Boolean, lockAutomatically: Boolean = false) {
        if (!fieldProfile.allowsShift) {
            shift = ShiftState.OFF
            return
        }
        if (lockAutomatically) {
            shift = ShiftState.LOCKED
            rebuildKeys(width, height)
            invalidate()
            return
        }
        if (shift != ShiftState.LOCKED) {
            shift = if (shouldShift) ShiftState.ONCE else ShiftState.OFF
            rebuildKeys(width, height)
            invalidate()
        }
    }

    fun updateSpeechState(
        state: SpeechSessionState,
        message: String,
        partial: String = partialTranscript,
        level: Float = audioLevel,
    ) {
        speechState = state
        speechMessage = message
        partialTranscript = partial
        audioLevel = level
        rebuildKeys(width, height)
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val landscape = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val desiredHeight = dp(if (landscape) 252f else 336f).toInt()
        setMeasuredDimension(width, resolveSize(desiredHeight, heightMeasureSpec))
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        rebuildKeys(w, h)
    }

    override fun dispatchHoverEvent(event: MotionEvent): Boolean =
        accessibilityHelper.dispatchHoverEvent(event) || super.dispatchHoverEvent(event)

    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean =
        accessibilityHelper.dispatchKeyEvent(event) || super.dispatchKeyEvent(event)

    override fun onFocusChanged(gainFocus: Boolean, direction: Int, previouslyFocusedRect: Rect?) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
        accessibilityHelper.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val dark = isDarkMode()
        canvas.drawColor(if (dark) Color.rgb(28, 29, 34) else Color.rgb(210, 213, 220))
        drawToolbarBackground(canvas, dark)
        keys.forEach { drawKey(canvas, it, dark) }
        if (swipePoints.size > 1) drawSwipeTrail(canvas)
        if (preferences.keyPreviewsEnabled && currentKey?.kind == KeyKind.TEXT && !isSwiping &&
            (!alternateArmed || alternateSelectionActive)
        ) {
            drawPreview(canvas, currentKey!!, dark)
        }
        if (punctuationPopupVisible) drawPunctuationPopup(canvas, dark)
    }

    private fun drawToolbarBackground(canvas: Canvas, dark: Boolean) {
        val toolbarBottom = toolbarHeight()
        paint.color = if (dark) Color.rgb(40, 41, 47) else Color.rgb(239, 240, 245)
        paint.style = Paint.Style.FILL
        canvas.drawRect(0f, 0f, width.toFloat(), toolbarBottom, paint)

        if (speechState == SpeechSessionState.LISTENING) {
            val meterWidth = (width - dp(120f)) * audioLevel.coerceIn(0f, 1f)
            paint.color = Color.rgb(220, 55, 69)
            canvas.drawRoundRect(dp(16f), toolbarBottom - dp(5f), dp(16f) + meterWidth, toolbarBottom - dp(2f), dp(2f), dp(2f), paint)
        }

        val text = when {
            partialTranscript.isNotBlank() && speechState != SpeechSessionState.IDLE -> partialTranscript
            speechState != SpeechSessionState.IDLE -> speechMessage
            fieldProfile.sensitive -> "Private field — dictation and suggestions off"
            else -> ""
        }
        if (text.isNotBlank()) {
            paint.color = if (dark) Color.WHITE else Color.rgb(45, 45, 52)
            paint.textSize = dp(13f)
            paint.textAlign = Paint.Align.LEFT
            canvas.drawText(text.take(62), dp(18f), toolbarBottom / 2f + dp(5f), paint)
            paint.textAlign = Paint.Align.CENTER
        }
    }

    private fun drawKey(canvas: Canvas, key: KeySpec, dark: Boolean) {
        val pressed = currentKey?.id == key.id && !isSwiping
        val control = key.kind != KeyKind.TEXT && key.kind != KeyKind.SPACE && key.kind != KeyKind.SUGGESTION
        paint.color = when {
            key.kind == KeyKind.MICROPHONE && speechState == SpeechSessionState.LISTENING -> Color.rgb(210, 52, 66)
            key.kind == KeyKind.MICROPHONE -> Color.rgb(82, 79, 205)
            pressed -> if (dark) Color.rgb(106, 107, 115) else Color.rgb(183, 185, 191)
            key.kind == KeyKind.SUGGESTION -> Color.TRANSPARENT
            control -> if (dark) Color.rgb(74, 75, 82) else Color.rgb(174, 177, 185)
            else -> if (dark) Color.rgb(85, 86, 93) else Color.rgb(248, 248, 251)
        }
        paint.style = Paint.Style.FILL
        canvas.drawRoundRect(key.rect, dp(5f), dp(5f), paint)

        paint.color = when {
            key.kind == KeyKind.MICROPHONE -> Color.WHITE
            dark -> Color.WHITE
            else -> Color.rgb(25, 25, 30)
        }
        paint.textSize = when (key.kind) {
            KeyKind.TEXT -> dp(21f)
            KeyKind.SUGGESTION -> dp(15f)
            else -> dp(15f)
        }
        paint.typeface = if (key.kind == KeyKind.SUGGESTION) boldPaint.typeface else Typeface.DEFAULT
        val baseline = key.rect.centerY() - (paint.ascent() + paint.descent()) / 2f
        canvas.drawText(displayLabel(key), key.rect.centerX(), baseline, paint)

        if (preferences.alternateSymbolsEnabled && key.alternate != null && page == KeyboardPage.LETTERS) {
            paint.textSize = dp(8f)
            paint.color = if (dark) Color.LTGRAY else Color.DKGRAY
            paint.textAlign = Paint.Align.RIGHT
            canvas.drawText(key.alternate, key.rect.right - dp(4f), key.rect.top + dp(10f), paint)
            paint.textAlign = Paint.Align.CENTER
        }
    }

    private fun displayLabel(key: KeySpec): String = when {
        key.kind == KeyKind.SHIFT && shift == ShiftState.LOCKED -> "⇪"
        key.kind == KeyKind.SHIFT -> "⇧"
        key.kind == KeyKind.DELETE -> "⌫"
        key.kind == KeyKind.ENTER && key.label == KeyboardReturnAction.RETURN.label -> "↵"
        key.kind == KeyKind.ENTER -> key.label
        key.kind == KeyKind.NEXT_INPUT -> "◉"
        key.kind == KeyKind.MICROPHONE && speechState == SpeechSessionState.LISTENING -> "■"
        key.kind == KeyKind.MICROPHONE -> "●"
        key.kind == KeyKind.SPACE && spaceCursorMode -> "Move cursor"
        else -> key.label
    }

    private fun accessibleLabel(key: KeySpec): String {
        val visible = when {
            key.kind == KeyKind.MICROPHONE && speechState == SpeechSessionState.LISTENING -> "Stop"
            key.kind == KeyKind.ENTER -> fieldProfile.returnAction.label
            else -> key.label
        }
        val alternate = key.alternate.takeIf { preferences.alternateSymbolsEnabled }
        return KeyboardAccessibilityLabels.labelFor(key.id, visible, alternate)
    }

    private fun drawSwipeTrail(canvas: Canvas) {
        val path = Path().apply {
            moveTo(swipePoints.first().first, swipePoints.first().second)
            swipePoints.drop(1).forEach { lineTo(it.first, it.second) }
        }
        canvas.drawPath(path, trailPaint)
    }

    private fun drawPreview(canvas: Canvas, key: KeySpec, dark: Boolean) {
        val label = if (alternateArmed) key.alternate ?: key.label else key.label
        val rect = RectF(
            key.rect.left - dp(4f),
            key.rect.top - dp(48f),
            key.rect.right + dp(4f),
            key.rect.top + dp(6f),
        )
        paint.color = if (dark) Color.rgb(110, 111, 120) else Color.WHITE
        canvas.drawRoundRect(rect, dp(8f), dp(8f), paint)
        paint.color = if (dark) Color.WHITE else Color.BLACK
        paint.textSize = dp(27f)
        val baseline = rect.centerY() - (paint.ascent() + paint.descent()) / 2f
        canvas.drawText(label, rect.centerX(), baseline, paint)
    }

    private fun drawPunctuationPopup(canvas: Canvas, dark: Boolean) {
        val period = keys.firstOrNull { it.id == "period" } ?: return
        val popup = punctuationPopupRect(period)
        paint.color = if (dark) Color.rgb(70, 71, 79) else Color.WHITE
        canvas.drawRoundRect(popup, dp(10f), dp(10f), paint)
        val rows = PUNCTUATION_ROWS
        val cellWidth = popup.width() / 8f
        val cellHeight = popup.height() / 2f
        rows.forEachIndexed { row, values ->
            values.forEachIndexed { column, value ->
                val cell = RectF(
                    popup.left + column * cellWidth,
                    popup.top + row * cellHeight,
                    popup.left + (column + 1) * cellWidth,
                    popup.top + (row + 1) * cellHeight,
                )
                if (selectedPunctuation == value) {
                    paint.color = Color.rgb(92, 88, 214)
                    canvas.drawRoundRect(cell, dp(6f), dp(6f), paint)
                }
                paint.color = if (selectedPunctuation == value || dark) Color.WHITE else Color.BLACK
                paint.textSize = dp(18f)
                canvas.drawText(value, cell.centerX(), cell.centerY() - (paint.ascent() + paint.descent()) / 2f, paint)
            }
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> beginTouch(event.x, event.y)
            MotionEvent.ACTION_MOVE -> moveTouch(event.x, event.y)
            MotionEvent.ACTION_UP -> {
                endTouch(event.x, event.y)
                performClick()
            }
            MotionEvent.ACTION_CANCEL -> cancelTouch()
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    private fun beginTouch(x: Float, y: Float) {
        currentKey = keyAt(x, y)
        downX = x
        downY = y
        cursorSteps = 0
        alternateArmed = false
        alternateSelectionActive = false
        deleteRepeated = false
        deleteRepeatCount = 0
        isSwiping = false
        spaceCursorMode = false
        swipePoints.clear()
        swipeKeys.clear()
        punctuationPopupVisible = false
        selectedPunctuation = null
        val key = currentKey ?: return
        feedback(HapticFeedbackConstants.KEYBOARD_TAP)
        if (key.kind == KeyKind.DELETE) handler.postDelayed(deleteRepeatRunnable, 450L)
        if (key.kind == KeyKind.SPACE) {
            handler.postDelayed(spaceCursorRunnable, KeyboardGestureRules.SPACE_CURSOR_HOLD_MILLIS)
        }
        if (key.alternate != null) handler.postDelayed(alternateRunnable, preferences.alternateHoldDelayMillis.toLong())
        if (key.id == "period" && preferences.alternateSymbolsEnabled) {
            handler.postDelayed(punctuationRunnable, preferences.alternateHoldDelayMillis.toLong())
        }
        if (key.kind == KeyKind.TEXT && key.output?.singleOrNull()?.isLetter() == true) {
            swipePoints += x to y
            swipeKeys += key.output.lowercase().single()
        }
        invalidate()
    }

    private fun moveTouch(x: Float, y: Float) {
        val key = currentKey ?: return
        val deltaX = x - downX
        val deltaY = y - downY
        if (key.kind == KeyKind.SPACE) {
            if (!spaceCursorMode) return
            val steps = (deltaX / dp(12f)).toInt()
            val delta = steps - cursorSteps
            if (delta != 0) {
                listener?.onMoveCursor(delta)
                cursorSteps = steps
                feedback(HapticFeedbackConstants.CLOCK_TICK)
            }
            return
        }
        if (key.kind == KeyKind.DELETE) {
            if (keyAt(x, y)?.id != key.id) {
                handler.removeCallbacks(deleteRepeatRunnable)
                currentKey = null
                invalidate()
            }
            return
        }
        if (punctuationPopupVisible) {
            selectedPunctuation = punctuationAt(x, y, key)
            invalidate()
            return
        }
        if (KeyboardGestureRules.shouldCancelAlternateHold(deltaX, deltaY)) {
            handler.removeCallbacks(alternateRunnable)
        }
        if (alternateArmed) {
            // Once the deliberate long-press has armed an alternate, sliding
            // must stay in that gesture instead of turning into a word swipe.
            alternateSelectionActive = KeyboardGestureRules.remainsInAlternateSelection(
                deltaX = deltaX,
                deltaY = deltaY,
                keyHeight = key.rect.height(),
            )
            invalidate()
            return
        }
        if (preferences.swipeTypingEnabled && key.kind == KeyKind.TEXT &&
            hypot(deltaX, deltaY) >= dp(KeyboardGestureRules.SWIPE_DISTANCE)
        ) {
            val hovered = keyAt(x, y)?.takeIf {
                it.kind == KeyKind.TEXT && it.output?.singleOrNull()?.isLetter() == true
            }
            if (hovered != null) {
                isSwiping = true
                alternateArmed = false
                handler.removeCallbacks(alternateRunnable)
                val character = hovered.output!!.lowercase().single()
                if (swipeKeys.lastOrNull() != character) swipeKeys += character
                swipePoints += x to y
                invalidate()
            }
        }
    }

    private fun endTouch(x: Float, y: Float) {
        handler.removeCallbacks(alternateRunnable)
        handler.removeCallbacks(deleteRepeatRunnable)
        handler.removeCallbacks(punctuationRunnable)
        handler.removeCallbacks(spaceCursorRunnable)
        val key = currentKey
        when {
            key == null -> Unit
            punctuationPopupVisible -> commitPunctuation(selectedPunctuation ?: ".")
            key.kind == KeyKind.DELETE && deleteRepeated -> Unit
            key.kind == KeyKind.SPACE && spaceCursorMode -> Unit
            isSwiping && swipeKeys.size >= 2 -> {
                listener?.onSwipe(swipeKeys.toList(), capitalize = shift != ShiftState.OFF)
                if (shift == ShiftState.ONCE) shift = ShiftState.OFF
            }
            alternateArmed && alternateSelectionActive && key.alternate != null -> commitAlternate(key)
            alternateArmed -> Unit
            key.kind == KeyKind.TEXT -> commitKey(key, downX, downY)
            key.kind == KeyKind.SPACE -> commitKey(key)
            keyAt(x, y)?.id == key.id -> commitKey(key)
        }
        cancelTouch()
    }

    private fun cancelTouch() {
        handler.removeCallbacks(alternateRunnable)
        handler.removeCallbacks(deleteRepeatRunnable)
        handler.removeCallbacks(punctuationRunnable)
        handler.removeCallbacks(spaceCursorRunnable)
        currentKey = null
        alternateArmed = false
        alternateSelectionActive = false
        deleteRepeated = false
        isSwiping = false
        spaceCursorMode = false
        cursorSteps = 0
        punctuationPopupVisible = false
        selectedPunctuation = null
        swipePoints.clear()
        swipeKeys.clear()
        invalidate()
    }

    private fun commitPunctuation(text: String) {
        playClick()
        listener?.onText(text)
        if (shouldReturnToLettersAfterSymbol()) {
            page = KeyboardPage.LETTERS
            rebuildKeys(width, height)
        }
    }

    private fun commitKey(key: KeySpec, touchX: Float? = null, touchY: Float? = null) {
        playClick()
        when (key.kind) {
            KeyKind.TEXT -> {
                val output = key.output.orEmpty()
                val isLetter = output.singleOrNull()?.isLetter() == true
                val evidence = if (isLetter && touchX != null && touchY != null) {
                    tapEvidence(output.lowercase().single(), touchX, touchY)
                } else {
                    null
                }
                listener?.onText(
                    if (isLetter && shift != ShiftState.OFF) output.uppercase() else output,
                    isLetter,
                    evidence,
                )
                if (isLetter && shift == ShiftState.ONCE) shift = ShiftState.OFF
                if (!isLetter && shouldReturnToLettersAfterSymbol()) page = KeyboardPage.LETTERS
            }
            KeyKind.SHIFT -> toggleShift()
            KeyKind.DELETE -> listener?.onDelete()
            KeyKind.SPACE -> listener?.onSpace()
            KeyKind.ENTER -> listener?.onEnter()
            KeyKind.MODE -> page = if (page == KeyboardPage.LETTERS) KeyboardPage.NUMBERS else KeyboardPage.LETTERS
            KeyKind.MORE_SYMBOLS -> page = if (page == KeyboardPage.SYMBOLS) KeyboardPage.NUMBERS else KeyboardPage.SYMBOLS
            KeyKind.NEXT_INPUT -> listener?.onNextInputMethod()
            KeyKind.MICROPHONE -> listener?.onToggleDictation()
            KeyKind.CANCEL -> listener?.onCancelDictation()
            KeyKind.UNDO_DICTATION -> listener?.onUndoDictation()
            KeyKind.UNDO_AUTOCORRECTION -> listener?.onUndoAutocorrection()
            KeyKind.SUGGESTION -> key.candidate?.let { listener?.onSuggestion(it) }
        }
        rebuildKeys(width, height)
        invalidate()
    }

    private fun commitAlternate(key: KeySpec) {
        val alternate = key.alternate ?: return
        playClick()
        listener?.onText(alternate)
        if (page == KeyboardPage.LETTERS &&
            key.output?.singleOrNull()?.isLetter() == true &&
            shift == ShiftState.ONCE
        ) {
            shift = ShiftState.OFF
        }
        if (shouldReturnToLettersAfterSymbol()) {
            page = KeyboardPage.LETTERS
        }
        rebuildKeys(width, height)
        invalidate()
    }

    private fun shouldReturnToLettersAfterSymbol(): Boolean =
        (page == KeyboardPage.NUMBERS || page == KeyboardPage.SYMBOLS) &&
            KeyboardEditingRules.shouldReturnToLetters(
                preferences.symbolTapBehavior,
                preferences.symbolTapScope,
                page == KeyboardPage.SYMBOLS,
            )

    private fun tapEvidence(character: Char, touchX: Float, touchY: Float): KeyboardTapEvidence {
        val distances = keys.asSequence().mapNotNull { key ->
            val candidate = key.output?.lowercase()?.singleOrNull()?.takeIf(Char::isLetter) ?: return@mapNotNull null
            val horizontal = (touchX - key.rect.centerX()) / key.rect.width().coerceAtLeast(1f)
            val vertical = (touchY - key.rect.centerY()) / key.rect.height().coerceAtLeast(1f)
            candidate to hypot(horizontal, vertical).toDouble()
        }.toMap()
        return KeyboardTapEvidence(character, distances)
    }

    private fun toggleShift() {
        val now = System.currentTimeMillis()
        shift = when {
            shift == ShiftState.LOCKED -> ShiftState.OFF
            now - lastShiftTapMillis < 320 -> ShiftState.LOCKED
            shift == ShiftState.OFF -> ShiftState.ONCE
            else -> ShiftState.OFF
        }
        lastShiftTapMillis = now
    }

    private fun rebuildKeys(viewWidth: Int, viewHeight: Int) {
        if (viewWidth <= 0 || viewHeight <= 0) return
        keys.clear()
        buildToolbar(viewWidth)
        val top = toolbarHeight() + dp(6f)
        keyAreaTop = top
        val bottomInset = dp(5f)
        val rowGap = dp(6f)
        val rowHeight = (viewHeight - top - bottomInset - rowGap * 3f) / 4f
        when (page) {
            KeyboardPage.LETTERS -> buildLetterRows(viewWidth, top, rowHeight, rowGap)
            KeyboardPage.NUMBERS -> buildSymbolRows(viewWidth, top, rowHeight, rowGap, false)
            KeyboardPage.SYMBOLS -> buildSymbolRows(viewWidth, top, rowHeight, rowGap, true)
            KeyboardPage.NUMBER_PAD -> buildNumberPad(viewWidth, top, rowHeight, rowGap)
            KeyboardPage.PHONE_PAD -> buildPhonePad(viewWidth, top, rowHeight, rowGap)
        }
        updateHitRegions(viewWidth, viewHeight)
        accessibilityHelper.invalidateRoot()
    }

    private fun updateHitRegions(viewWidth: Int, viewHeight: Int) {
        val frames = keys.asSequence()
            .filterNot { it.kind.isToolbarControl() }
            .associate { key ->
                key.id to KeyboardHitRect(
                    key.rect.left,
                    key.rect.top,
                    key.rect.right,
                    key.rect.bottom,
                )
            }
        hitRegions = KeyboardHitGrid.regions(
            frames,
            KeyboardHitRect(0f, keyAreaTop, viewWidth.toFloat(), viewHeight.toFloat()),
        )
    }

    private fun keyAt(x: Float, y: Float): KeySpec? {
        if (y < keyAreaTop) return keys.lastOrNull { it.rect.contains(x, y) }
        val bias = if (resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) {
            KeyboardHitGrid.COMPACT_VERTICAL_TAP_BIAS
        } else {
            KeyboardHitGrid.PORTRAIT_VERTICAL_TAP_BIAS
        }
        val id = KeyboardHitGrid.keyAt(
            x,
            y,
            hitRegions,
            verticalTapBias = dp(bias),
            maximumOutsideDistance = dp(KeyboardHitGrid.MAXIMUM_OUTSIDE_DISTANCE),
        ) ?: return null
        return keys.firstOrNull { it.id == id }
    }

    private fun buildToolbar(viewWidth: Int) {
        val top = dp(5f)
        val bottom = toolbarHeight() - dp(5f)
        val micWidth = if (fieldProfile.allowsDictation) dp(62f) else 0f
        val gap = dp(6f)
        val micLeft = viewWidth - dp(6f) - micWidth
        val active = speechState == SpeechSessionState.PREPARING ||
            speechState == SpeechSessionState.LISTENING ||
            speechState == SpeechSessionState.PROCESSING
        if (active) {
            keys += KeySpec("cancel", "Cancel", kind = KeyKind.CANCEL, rect = RectF(dp(6f), top, dp(72f), bottom))
        } else if (autocorrectionUndoOriginal != null) {
            keys += KeySpec(
                id = "undo-autocorrection",
                label = "Undo to $autocorrectionUndoOriginal",
                kind = KeyKind.UNDO_AUTOCORRECTION,
                rect = RectF(dp(6f), top, micLeft - gap, bottom),
            )
        } else if (suggestions.isNotEmpty()) {
            val candidateWidth = (micLeft - dp(12f) - gap * 2f) / 3f
            suggestions.take(3).forEachIndexed { index, suggestion ->
                val left = dp(6f) + index * (candidateWidth + gap)
                keys += KeySpec(
                    id = "suggestion-$index",
                    label = suggestion.text,
                    kind = KeyKind.SUGGESTION,
                    rect = RectF(left, top, left + candidateWidth, bottom),
                    candidate = suggestion,
                )
            }
        } else if (undoDictationAvailable) {
            keys += KeySpec(
                id = "undo-dictation",
                label = "Undo dictation",
                kind = KeyKind.UNDO_DICTATION,
                rect = RectF(dp(6f), top, micLeft - gap, bottom),
            )
        }
        if (fieldProfile.allowsDictation) {
            keys += KeySpec(
                id = "microphone",
                label = "Dictate",
                kind = KeyKind.MICROPHONE,
                rect = RectF(micLeft, top, viewWidth - dp(6f), bottom),
            )
        }
    }

    private fun buildLetterRows(viewWidth: Int, top: Float, rowHeight: Float, rowGap: Float) {
        addCharacterRow("qwertyuiop", viewWidth, top, rowHeight, 0.02f)
        addCharacterRow("asdfghjkl", viewWidth, top + rowHeight + rowGap, rowHeight, 0.06f)

        val thirdTop = top + (rowHeight + rowGap) * 2f
        val sideWidth = dp(48f)
        keys += KeySpec("shift", "Shift", kind = KeyKind.SHIFT, rect = RectF(dp(4f), thirdTop, dp(4f) + sideWidth, thirdTop + rowHeight))
        addCharacterRow("zxcvbnm", viewWidth, thirdTop, rowHeight, 0.15f, sideWidth + dp(3f))
        keys += KeySpec("delete", "Delete", kind = KeyKind.DELETE, rect = RectF(viewWidth - dp(4f) - sideWidth, thirdTop, viewWidth - dp(4f), thirdTop + rowHeight))
        addBottomRow(viewWidth, top + (rowHeight + rowGap) * 3f, rowHeight, "123")
    }

    private fun addCharacterRow(
        letters: String,
        viewWidth: Int,
        top: Float,
        rowHeight: Float,
        insetFraction: Float,
        forcedSideInset: Float? = null,
    ) {
        val gap = dp(5f)
        val inset = forcedSideInset ?: viewWidth * insetFraction
        val keyWidth = (viewWidth - inset * 2f - gap * (letters.length - 1)) / letters.length
        letters.forEachIndexed { index, character ->
            val left = inset + index * (keyWidth + gap)
            val output = character.toString()
            keys += KeySpec(
                id = "key-$character",
                label = if (shift == ShiftState.OFF) output else output.uppercase(),
                output = output,
                rect = RectF(left, top, left + keyWidth, top + rowHeight),
                alternate = KeyboardAlternateSymbols.alternateFor(character),
            )
        }
    }

    private fun buildSymbolRows(viewWidth: Int, top: Float, rowHeight: Float, rowGap: Float, symbols: Boolean) {
        val layout = if (symbols) SYMBOL_ROWS else NUMBER_ROWS
        addTextRow(layout[0], viewWidth, top, rowHeight, dp(4f), allowsAlternates = !symbols)
        addTextRow(layout[1], viewWidth, top + rowHeight + rowGap, rowHeight, dp(4f))
        val thirdTop = top + (rowHeight + rowGap) * 2f
        val sideWidth = dp(52f)
        keys += KeySpec(
            "more-symbols",
            if (symbols) "123" else "#+=",
            kind = KeyKind.MORE_SYMBOLS,
            rect = RectF(dp(4f), thirdTop, dp(4f) + sideWidth, thirdTop + rowHeight),
        )
        addTextRow(layout[2], viewWidth, thirdTop, rowHeight, sideWidth + dp(11f))
        keys += KeySpec("delete", "Delete", kind = KeyKind.DELETE, rect = RectF(viewWidth - dp(4f) - sideWidth, thirdTop, viewWidth - dp(4f), thirdTop + rowHeight))
        addBottomRow(viewWidth, top + (rowHeight + rowGap) * 3f, rowHeight, "ABC")
    }

    private fun buildNumberPad(viewWidth: Int, top: Float, rowHeight: Float, rowGap: Float) {
        addTextRow(listOf("1", "2", "3"), viewWidth, top, rowHeight, viewWidth * 0.19f)
        addTextRow(listOf("4", "5", "6"), viewWidth, top + rowHeight + rowGap, rowHeight, viewWidth * 0.19f)
        addTextRow(listOf("7", "8", "9"), viewWidth, top + (rowHeight + rowGap) * 2f, rowHeight, viewWidth * 0.19f)
        val extras = when (fieldProfile.layout) {
            KeyboardFieldLayout.DATE -> listOf("/", "0", "-", ".")
            KeyboardFieldLayout.TIME -> listOf(":", "0", "AM", "PM")
            KeyboardFieldLayout.DATETIME -> listOf("/", "0", ":", "-")
            else -> buildList {
                if (fieldProfile.signedNumber) add("-")
                add("0")
                if (fieldProfile.decimalNumber) add(".")
            }
        }
        addPadBottomRow(viewWidth, top + (rowHeight + rowGap) * 3f, rowHeight, extras)
    }

    private fun buildPhonePad(viewWidth: Int, top: Float, rowHeight: Float, rowGap: Float) {
        addTextRow(listOf("1", "2", "3"), viewWidth, top, rowHeight, viewWidth * 0.19f)
        addTextRow(listOf("4", "5", "6"), viewWidth, top + rowHeight + rowGap, rowHeight, viewWidth * 0.19f)
        addTextRow(listOf("7", "8", "9"), viewWidth, top + (rowHeight + rowGap) * 2f, rowHeight, viewWidth * 0.19f)
        addPadBottomRow(viewWidth, top + (rowHeight + rowGap) * 3f, rowHeight, listOf("*", "0", "#", "+"))
    }

    private fun addPadBottomRow(viewWidth: Int, top: Float, rowHeight: Float, values: List<String>) {
        val gap = dp(5f)
        val inset = dp(4f)
        val nextWidth = if (offersInputModeSwitch) dp(42f) else 0f
        val deleteWidth = dp(52f)
        val returnWidth = dp(64f)
        var left = inset
        if (offersInputModeSwitch) {
            keys += KeySpec("next", "Next", kind = KeyKind.NEXT_INPUT, rect = RectF(left, top, left + nextWidth, top + rowHeight))
            left += nextWidth + gap
        }
        val controlsWidth = deleteWidth + returnWidth + gap * 2f
        val available = viewWidth - left - inset - controlsWidth
        val valueWidth = (available - gap * (values.size - 1).coerceAtLeast(0)) / values.size.coerceAtLeast(1)
        values.forEachIndexed { index, value ->
            val valueLeft = left + index * (valueWidth + gap)
            keys += KeySpec(
                id = "pad-$value-$index",
                label = value,
                output = value,
                rect = RectF(valueLeft, top, valueLeft + valueWidth, top + rowHeight),
            )
        }
        left += available + gap
        keys += KeySpec("delete", "Delete", kind = KeyKind.DELETE, rect = RectF(left, top, left + deleteWidth, top + rowHeight))
        left += deleteWidth + gap
        keys += KeySpec(
            "return",
            fieldProfile.returnAction.label,
            kind = KeyKind.ENTER,
            rect = RectF(left, top, viewWidth - inset, top + rowHeight),
        )
    }

    private fun addTextRow(
        values: List<String>,
        viewWidth: Int,
        top: Float,
        rowHeight: Float,
        inset: Float,
        allowsAlternates: Boolean = false,
    ) {
        val gap = dp(5f)
        val keyWidth = (viewWidth - inset * 2f - gap * (values.size - 1)) / values.size
        values.forEachIndexed { index, value ->
            val left = inset + index * (keyWidth + gap)
            keys += KeySpec(
                id = "symbol-$value-$index-${top.toInt()}",
                label = value,
                output = value,
                rect = RectF(left, top, left + keyWidth, top + rowHeight),
                alternate = if (allowsAlternates) {
                    value.singleOrNull()?.let(KeyboardAlternateSymbols::alternateFor)
                } else {
                    null
                },
            )
        }
    }

    private fun addBottomRow(viewWidth: Int, top: Float, rowHeight: Float, modeLabel: String) {
        val gap = dp(5f)
        val inset = dp(4f)
        val modeWidth = dp(54f)
        val nextWidth = if (offersInputModeSwitch) dp(42f) else 0f
        val punctuationWidth = dp(38f)
        val returnWidth = dp(58f)
        var left = inset
        keys += KeySpec("mode", modeLabel, kind = KeyKind.MODE, rect = RectF(left, top, left + modeWidth, top + rowHeight))
        left += modeWidth + gap
        if (offersInputModeSwitch) {
            keys += KeySpec("next", "Next", kind = KeyKind.NEXT_INPUT, rect = RectF(left, top, left + nextWidth, top + rowHeight))
            left += nextWidth + gap
        }
        val spaceRight = viewWidth - inset - returnWidth - gap - punctuationWidth - gap
        keys += KeySpec("space", "space", kind = KeyKind.SPACE, rect = RectF(left, top, spaceRight, top + rowHeight))
        left = spaceRight + gap
        val punctuation = when (fieldProfile.layout) {
            KeyboardFieldLayout.EMAIL -> "@"
            KeyboardFieldLayout.URI -> "/"
            else -> "."
        }
        keys += KeySpec(
            if (punctuation == ".") "period" else "field-punctuation",
            punctuation,
            output = punctuation,
            rect = RectF(left, top, left + punctuationWidth, top + rowHeight),
        )
        left += punctuationWidth + gap
        keys += KeySpec(
            "return",
            fieldProfile.returnAction.label,
            kind = KeyKind.ENTER,
            rect = RectF(left, top, viewWidth - inset, top + rowHeight),
        )
    }

    private fun punctuationPopupRect(period: KeySpec): RectF {
        val width = minOf(dp(320f), period.rect.right - dp(6f))
        val height = dp(84f)
        return RectF(period.rect.right - width, period.rect.top - height - dp(8f), period.rect.right, period.rect.top - dp(8f))
    }

    private fun punctuationAt(x: Float, y: Float, period: KeySpec): String? {
        val popup = punctuationPopupRect(period)
        if (!popup.contains(x, y)) return selectedPunctuation
        val column = ((x - popup.left) / (popup.width() / 8f)).toInt().coerceIn(0, 7)
        val row = ((y - popup.top) / (popup.height() / 2f)).toInt().coerceIn(0, 1)
        return PUNCTUATION_ROWS[row][column]
    }

    private fun feedback(constant: Int) {
        if (preferences.hapticsEnabled) performHapticFeedback(constant)
    }

    private fun playClick() {
        audioManager?.playSoundEffect(AudioManager.FX_KEY_CLICK, 0.45f)
    }

    private fun toolbarHeight() = dp(52f)
    private fun dp(value: Float) = value * density
    private fun isDarkMode() = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    private fun KeyKind.isToolbarControl(): Boolean = when (this) {
        KeyKind.MICROPHONE, KeyKind.CANCEL, KeyKind.UNDO_DICTATION,
        KeyKind.UNDO_AUTOCORRECTION, KeyKind.SUGGESTION -> true
        else -> false
    }

    companion object {
        private val NUMBER_ROWS = listOf(
            "1234567890".map(Char::toString),
            listOf("-", "/", ":", ";", "(", ")", "$", "&", "@", "\""),
            listOf(".", ",", "?", "!", "'"),
        )
        private val SYMBOL_ROWS = listOf(
            listOf("[", "]", "{", "}", "#", "%", "^", "*", "+", "="),
            listOf("_", "\\", "|", "~", "<", ">", "€", "£", "¥"),
            listOf(".", ",", "?", "!", "'"),
        )
        private val PUNCTUATION_ROWS = listOf(
            listOf("&", "%", "+", "\"", "-", ":", "'", "@"),
            listOf(";", "/", "(", ")", "#", "!", ",", "?"),
        )
    }
}
