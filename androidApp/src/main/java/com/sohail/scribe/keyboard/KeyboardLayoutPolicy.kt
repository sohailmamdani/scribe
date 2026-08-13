package com.sohail.scribe.keyboard

enum class KeyboardLayoutMode { COMPACT, SPLIT }

data class KeyboardGeometry(
    val toolbarHeightDp: Float,
    val keyHeightDp: Float,
    val rowGapDp: Float,
    val topGapDp: Float,
    val bottomPaddingDp: Float,
) {
    val contentHeightDp: Float
        get() = toolbarHeightDp + topGapDp + keyHeightDp * 5f + rowGapDp * 4f + bottomPaddingDp
}

/** Pure layout decisions kept outside the View so phone/foldable geometry is JVM-testable. */
object KeyboardLayoutPolicy {
    const val MINIMUM_SPLIT_WIDTH_DP = 600
    const val MINIMUM_SPLIT_SCREEN_HEIGHT_DP = 480

    val portraitGeometry = KeyboardGeometry(
        toolbarHeightDp = 56f,
        keyHeightDp = 43f,
        rowGapDp = 7f,
        topGapDp = 6f,
        bottomPaddingDp = 8f,
    )

    val landscapeGeometry = KeyboardGeometry(
        toolbarHeightDp = 44f,
        keyHeightDp = 42f,
        rowGapDp = 9f,
        topGapDp = 5f,
        bottomPaddingDp = 6f,
    )

    fun geometry(landscape: Boolean): KeyboardGeometry =
        if (landscape) landscapeGeometry else portraitGeometry

    fun layoutMode(
        widthDp: Int,
        screenHeightDp: Int,
        splitWideLayoutsEnabled: Boolean,
    ): KeyboardLayoutMode = if (
        splitWideLayoutsEnabled &&
        widthDp >= MINIMUM_SPLIT_WIDTH_DP &&
        screenHeightDp >= MINIMUM_SPLIT_SCREEN_HEIGHT_DP
    ) {
        KeyboardLayoutMode.SPLIT
    } else {
        KeyboardLayoutMode.COMPACT
    }

    /** Matches the supplied Gboard foldable reference: a deliberately large thumb-reach void. */
    fun splitGapDp(widthDp: Float): Float = widthDp * 0.42f

    fun splitOuterInsetDp(widthDp: Float): Float = widthDp * 0.042f
}
