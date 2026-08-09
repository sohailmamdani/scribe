package com.sohail.scribe.keyboard

import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import com.sohail.scribe.core.KeyboardEditingRules
import com.sohail.scribe.core.KeyboardPreferences
import com.sohail.scribe.speech.SpeechSessionState
import kotlin.math.hypot

interface KeyboardActionListener {
    fun onText(text: String, isLetter: Boolean = false)
    fun onDelete()
    fun onSpace()
    fun onEnter()
    fun onMoveCursor(characters: Int)
    fun onSwipe(keys: List<Char>)
    fun onSuggestion(candidate: CorrectionCandidate)
    fun onNextInputMethod()
    fun onToggleDictation()
    fun onCancelDictation()
}

private enum class KeyboardPage { LETTERS, NUMBERS, SYMBOLS }
private enum class ShiftState { OFF, ONCE, LOCKED }
private enum class KeyKind {
    TEXT, SHIFT, DELETE, SPACE, ENTER, MODE, MORE_SYMBOLS, NEXT_INPUT, MICROPHONE, CANCEL, SUGGESTION
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
    private val swipePoints = mutableListOf<Pair<Float, Float>>()
    private val swipeKeys = mutableListOf<Char>()
    private var page = KeyboardPage.LETTERS
    private var shift = ShiftState.ONCE
    private var lastShiftTapMillis = 0L
    private var preferences = KeyboardPreferences()
    private var suggestions: List<CorrectionCandidate> = emptyList()
    private var speechState = SpeechSessionState.IDLE
    private var speechMessage = "Dictate"
    private var partialTranscript = ""
    private var audioLevel = 0f
    private var currentKey: KeySpec? = null
    private var downX = 0f
    private var downY = 0f
    private var alternateArmed = false
    private var deleteRepeated = false
    private var isSwiping = false
    private var cursorSteps = 0
    private var punctuationPopupVisible = false
    private var selectedPunctuation: String? = null

    private val alternateRunnable = Runnable {
        val key = currentKey ?: return@Runnable
        if (preferences.alternateSymbolsEnabled && key.alternate != null && !isSwiping) {
            alternateArmed = true
            feedback(HapticFeedbackConstants.LONG_PRESS)
            invalidate()
        }
    }
    private val deleteRepeatRunnable = object : Runnable {
        override fun run() {
            if (currentKey?.kind != KeyKind.DELETE) return
            deleteRepeated = true
            listener?.onDelete()
            feedback(HapticFeedbackConstants.KEYBOARD_TAP)
            handler.postDelayed(this, 55L)
        }
    }
    private val punctuationRunnable = Runnable {
        if (currentKey?.id == "period") {
            punctuationPopupVisible = true
            selectedPunctuation = "."
            feedback(HapticFeedbackConstants.LONG_PRESS)
            invalidate()
        }
    }

    init {
        isFocusable = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        contentDescription = "Scribe keyboard"
    }

    fun updatePreferences(value: KeyboardPreferences) {
        preferences = value.normalized()
        invalidate()
    }

    fun updateSuggestions(value: List<CorrectionCandidate>) {
        suggestions = value
        rebuildKeys(width, height)
        invalidate()
    }

    fun updateAutomaticShift(shouldShift: Boolean) {
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

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val dark = isDarkMode()
        canvas.drawColor(if (dark) Color.rgb(28, 29, 34) else Color.rgb(210, 213, 220))
        drawToolbarBackground(canvas, dark)
        keys.forEach { drawKey(canvas, it, dark) }
        if (swipePoints.size > 1) drawSwipeTrail(canvas)
        if (preferences.keyPreviewsEnabled && currentKey?.kind == KeyKind.TEXT && !isSwiping) {
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
        key.kind == KeyKind.ENTER -> "↵"
        key.kind == KeyKind.NEXT_INPUT -> "◉"
        key.kind == KeyKind.MICROPHONE && speechState == SpeechSessionState.LISTENING -> "■"
        key.kind == KeyKind.MICROPHONE -> "●"
        else -> key.label
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
            MotionEvent.ACTION_UP -> endTouch(event.x, event.y)
            MotionEvent.ACTION_CANCEL -> cancelTouch()
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    private fun beginTouch(x: Float, y: Float) {
        currentKey = keys.lastOrNull { it.rect.contains(x, y) }
        downX = x
        downY = y
        cursorSteps = 0
        alternateArmed = false
        deleteRepeated = false
        isSwiping = false
        swipePoints.clear()
        swipeKeys.clear()
        punctuationPopupVisible = false
        selectedPunctuation = null
        val key = currentKey ?: return
        feedback(HapticFeedbackConstants.KEYBOARD_TAP)
        if (key.kind == KeyKind.DELETE) handler.postDelayed(deleteRepeatRunnable, 380L)
        if (key.alternate != null) handler.postDelayed(alternateRunnable, preferences.alternateHoldDelayMillis.toLong())
        if (key.id == "period") handler.postDelayed(punctuationRunnable, 380L)
        if (key.kind == KeyKind.TEXT && key.output?.singleOrNull()?.isLetter() == true) {
            swipePoints += x to y
            swipeKeys += key.output.lowercase().single()
        }
        invalidate()
    }

    private fun moveTouch(x: Float, y: Float) {
        val key = currentKey ?: return
        if (key.kind == KeyKind.SPACE) {
            val steps = ((x - downX) / dp(12f)).toInt()
            val delta = steps - cursorSteps
            if (delta != 0) {
                listener?.onMoveCursor(delta)
                cursorSteps = steps
                feedback(HapticFeedbackConstants.CLOCK_TICK)
            }
            return
        }
        if (punctuationPopupVisible) {
            selectedPunctuation = punctuationAt(x, y, key)
            invalidate()
            return
        }
        if (preferences.swipeTypingEnabled && key.kind == KeyKind.TEXT && hypot(x - downX, y - downY) >= dp(24f)) {
            val hovered = keys.lastOrNull {
                it.rect.contains(x, y) && it.kind == KeyKind.TEXT && it.output?.singleOrNull()?.isLetter() == true
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
        val key = currentKey
        when {
            key == null -> Unit
            punctuationPopupVisible -> listener?.onText(selectedPunctuation ?: ".")
            key.kind == KeyKind.DELETE && deleteRepeated -> Unit
            key.kind == KeyKind.SPACE && cursorSteps != 0 -> Unit
            isSwiping && swipeKeys.size >= 2 -> listener?.onSwipe(swipeKeys.toList())
            alternateArmed && key.alternate != null -> listener?.onText(key.alternate)
            key.rect.contains(x, y) || key.kind == KeyKind.SPACE -> commitKey(key)
        }
        performClick()
        cancelTouch()
    }

    private fun cancelTouch() {
        handler.removeCallbacks(alternateRunnable)
        handler.removeCallbacks(deleteRepeatRunnable)
        handler.removeCallbacks(punctuationRunnable)
        currentKey = null
        alternateArmed = false
        deleteRepeated = false
        isSwiping = false
        cursorSteps = 0
        punctuationPopupVisible = false
        selectedPunctuation = null
        swipePoints.clear()
        swipeKeys.clear()
        invalidate()
    }

    private fun commitKey(key: KeySpec) {
        playClick()
        when (key.kind) {
            KeyKind.TEXT -> {
                val output = key.output.orEmpty()
                val isLetter = output.singleOrNull()?.isLetter() == true
                listener?.onText(if (isLetter && shift != ShiftState.OFF) output.uppercase() else output, isLetter)
                if (isLetter && shift == ShiftState.ONCE) shift = ShiftState.OFF
                if (!isLetter && page != KeyboardPage.LETTERS && KeyboardEditingRules.shouldReturnToLetters(
                        preferences.symbolTapBehavior,
                        preferences.symbolTapScope,
                        page == KeyboardPage.SYMBOLS,
                    )
                ) page = KeyboardPage.LETTERS
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
            KeyKind.SUGGESTION -> key.candidate?.let { listener?.onSuggestion(it) }
        }
        rebuildKeys(width, height)
        invalidate()
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
        val bottomInset = dp(5f)
        val rowGap = dp(6f)
        val rowHeight = (viewHeight - top - bottomInset - rowGap * 3f) / 4f
        when (page) {
            KeyboardPage.LETTERS -> buildLetterRows(viewWidth, top, rowHeight, rowGap)
            KeyboardPage.NUMBERS -> buildSymbolRows(viewWidth, top, rowHeight, rowGap, false)
            KeyboardPage.SYMBOLS -> buildSymbolRows(viewWidth, top, rowHeight, rowGap, true)
        }
    }

    private fun buildToolbar(viewWidth: Int) {
        val top = dp(5f)
        val bottom = toolbarHeight() - dp(5f)
        val micWidth = dp(62f)
        val gap = dp(6f)
        val micLeft = viewWidth - dp(6f) - micWidth
        val active = speechState == SpeechSessionState.LISTENING || speechState == SpeechSessionState.PROCESSING
        if (active) {
            keys += KeySpec("cancel", "Cancel", kind = KeyKind.CANCEL, rect = RectF(dp(6f), top, dp(72f), bottom))
        } else {
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
        }
        keys += KeySpec(
            id = "microphone",
            label = "Dictate",
            kind = KeyKind.MICROPHONE,
            rect = RectF(micLeft, top, viewWidth - dp(6f), bottom),
        )
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
                alternate = ALTERNATES[character],
            )
        }
    }

    private fun buildSymbolRows(viewWidth: Int, top: Float, rowHeight: Float, rowGap: Float, symbols: Boolean) {
        val layout = if (symbols) SYMBOL_ROWS else NUMBER_ROWS
        addTextRow(layout[0], viewWidth, top, rowHeight, dp(4f))
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

    private fun addTextRow(values: List<String>, viewWidth: Int, top: Float, rowHeight: Float, inset: Float) {
        val gap = dp(5f)
        val keyWidth = (viewWidth - inset * 2f - gap * (values.size - 1)) / values.size
        values.forEachIndexed { index, value ->
            val left = inset + index * (keyWidth + gap)
            keys += KeySpec(
                id = if (value == ".") "period" else "symbol-$value-$index",
                label = value,
                output = value,
                rect = RectF(left, top, left + keyWidth, top + rowHeight),
            )
        }
    }

    private fun addBottomRow(viewWidth: Int, top: Float, rowHeight: Float, modeLabel: String) {
        val gap = dp(5f)
        val inset = dp(4f)
        val modeWidth = dp(54f)
        val nextWidth = dp(42f)
        val punctuationWidth = dp(38f)
        val returnWidth = dp(58f)
        var left = inset
        keys += KeySpec("mode", modeLabel, kind = KeyKind.MODE, rect = RectF(left, top, left + modeWidth, top + rowHeight))
        left += modeWidth + gap
        keys += KeySpec("next", "Next", kind = KeyKind.NEXT_INPUT, rect = RectF(left, top, left + nextWidth, top + rowHeight))
        left += nextWidth + gap
        val spaceRight = viewWidth - inset - returnWidth - gap - punctuationWidth - gap
        keys += KeySpec("space", "space", kind = KeyKind.SPACE, rect = RectF(left, top, spaceRight, top + rowHeight))
        left = spaceRight + gap
        keys += KeySpec("period", ".", output = ".", rect = RectF(left, top, left + punctuationWidth, top + rowHeight))
        left += punctuationWidth + gap
        keys += KeySpec("return", "return", kind = KeyKind.ENTER, rect = RectF(left, top, viewWidth - inset, top + rowHeight))
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

    companion object {
        private val ALTERNATES = mapOf(
            'q' to "1", 'w' to "2", 'e' to "3", 'r' to "4", 't' to "5",
            'y' to "6", 'u' to "7", 'i' to "8", 'o' to "9", 'p' to "0",
            'a' to "@", 's' to "#", 'd' to "$", 'f' to "&", 'g' to "*",
            'h' to "(", 'j' to ")", 'k' to "'", 'l' to "\"",
            'z' to "%", 'x' to "-", 'c' to "+", 'v' to "=", 'b' to "/",
            'n' to ";", 'm' to ":",
        )
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
