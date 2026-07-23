package com.ircmobile.app

import io.flutter.plugin.common.MethodChannel

object ForegroundBridge {
    private var channel: MethodChannel? = null
    private var pendingSelection: String? = null
    private var pendingRadioState: Map<String, Any?>? = null
    private var pendingMessagesDismissed = false

    fun attach(nextChannel: MethodChannel) {
        channel = nextChannel
        if (pendingMessagesDismissed) {
            nextChannel.invokeMethod("foregroundMessagesDismissed", null)
            pendingMessagesDismissed = false
        }
        pendingRadioState?.let {
            nextChannel.invokeMethod("radioStateChanged", it)
            pendingRadioState = null
        }
    }

    fun detach(oldChannel: MethodChannel) {
        if (channel == oldChannel) {
            channel = null
        }
    }

    fun foregroundSelection(payload: String?) {
        val cleanPayload = payload?.takeIf { it.isNotBlank() } ?: return
        val activeChannel = channel
        if (activeChannel == null) {
            pendingSelection = cleanPayload
        } else {
            activeChannel.invokeMethod("foregroundSelection", cleanPayload)
            pendingSelection = null
        }
    }

    fun popForegroundSelection(): String? {
        val payload = pendingSelection
        pendingSelection = null
        return payload
    }

    fun foregroundMessagesDismissed() {
        val activeChannel = channel
        if (activeChannel == null) {
            pendingMessagesDismissed = true
        } else {
            activeChannel.invokeMethod("foregroundMessagesDismissed", null)
        }
    }

    fun radioStateChanged(
        radioPlaying: Boolean,
        status: String,
        userStopped: Boolean,
    ) {
        val state = mapOf(
            "radioPlaying" to radioPlaying,
            "status" to status,
            "userStopped" to userStopped,
        )
        val activeChannel = channel
        if (activeChannel == null) {
            pendingRadioState = state
        } else {
            activeChannel.invokeMethod("radioStateChanged", state)
        }
    }
}
