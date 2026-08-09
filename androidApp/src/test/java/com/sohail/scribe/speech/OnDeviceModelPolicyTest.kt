package com.sohail.scribe.speech

import kotlin.test.Test
import kotlin.test.assertEquals

class OnDeviceModelPolicyTest {
    @Test fun installedModelTakesPriorityOverPendingOrDownloadableStates() {
        assertEquals(
            OnDeviceModelStatus.READY,
            OnDeviceModelPolicy.status(listOf("en-US"), listOf("fr-FR"), listOf("de-DE")),
        )
    }

    @Test fun pendingAndDownloadableStatesRemainActionable() {
        assertEquals(
            OnDeviceModelStatus.PENDING,
            OnDeviceModelPolicy.status(emptyList(), listOf("en-US"), listOf("en-US")),
        )
        assertEquals(
            OnDeviceModelStatus.DOWNLOADABLE,
            OnDeviceModelPolicy.status(emptyList(), emptyList(), listOf("en-US")),
        )
        assertEquals(
            OnDeviceModelStatus.UNKNOWN,
            OnDeviceModelPolicy.status(emptyList(), emptyList(), emptyList()),
        )
    }
}
