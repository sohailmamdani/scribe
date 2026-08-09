package com.sohail.scribe.keyboard

import java.util.concurrent.atomic.AtomicLong

/**
 * Rejects asynchronous keyboard work after the document or edit context changes.
 *
 * Candidate generation and swipe decoding share this gate deliberately: a new
 * edit supersedes both kinds of work, and an input lifecycle transition
 * invalidates everything that could otherwise mutate the next application's
 * InputConnection.
 */
internal class KeyboardDocumentWorkGate {
    private val generation = AtomicLong()

    fun begin(): Long = generation.incrementAndGet()

    fun invalidate() {
        generation.incrementAndGet()
    }

    fun accepts(token: Long): Boolean = generation.get() == token
}
