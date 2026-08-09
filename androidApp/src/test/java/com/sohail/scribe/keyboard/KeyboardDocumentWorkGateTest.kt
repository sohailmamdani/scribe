package com.sohail.scribe.keyboard

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class KeyboardDocumentWorkGateTest {
    @Test fun anInputTransitionRejectsPendingDocumentWork() {
        val gate = KeyboardDocumentWorkGate()
        val swipe = gate.begin()
        assertTrue(gate.accepts(swipe))

        gate.invalidate()

        assertFalse(gate.accepts(swipe))
    }

    @Test fun aNewEditSupersedesOlderCandidateOrSwipeWork() {
        val gate = KeyboardDocumentWorkGate()
        val older = gate.begin()
        val newer = gate.begin()

        assertFalse(gate.accepts(older))
        assertTrue(gate.accepts(newer))
    }
}
