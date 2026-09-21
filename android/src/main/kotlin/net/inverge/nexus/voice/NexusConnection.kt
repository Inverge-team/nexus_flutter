package net.inverge.nexus.voice

import android.content.Context
import android.os.Build
import android.telecom.Connection
import android.telecom.DisconnectCause
import androidx.annotation.RequiresApi

/**
 * One live call in the system Telecom UI. The system invokes [onAnswer] /
 * [onReject] / [onDisconnect] directly — NO Activity is launched — which is how
 * we answer "like a normal phone call" without opening the app. On answer we
 * start [NexusCallForegroundService], which brings up the media headlessly.
 */
@RequiresApi(Build.VERSION_CODES.O)
class NexusConnection(
    private val context: Context,
    private val callId: String,
    private val from: String = "",
    private val displayName: String? = null,
) : Connection() {

    init {
        connectionProperties = PROPERTY_SELF_MANAGED
    }

    /** The OS asks a self-managed connection to present its OWN incoming UI here
     *  (the system draws none). Post our lock-screen CallStyle notification. */
    override fun onShowIncomingCallUi() {
        NexusCallNotification.show(context, callId, from, displayName)
    }

    /** Also show immediately on ring, in case onShowIncomingCallUi is skipped. */
    fun presentIncomingUi() {
        NexusCallNotification.show(context, callId, from, displayName)
    }

    override fun onAnswer() {
        onAnswer(android.telecom.VideoProfile.STATE_AUDIO_ONLY)
    }

    override fun onAnswer(videoState: Int) {
        NexusCallNotification.cancel(context, callId)
        setActive()
        // Connect the media in the app's MAIN Flutter engine (the proven LiveKit
        // path). Bring the app to the foreground and hand it the call to answer.
        NexusVoiceManager.answerInApp(context, callId)
        // If the engine is already alive, this also notifies it directly.
        NexusVoiceManager.events?.onAnswer(callId)
    }

    override fun onReject() {
        NexusCallNotification.cancel(context, callId)
        NexusVoiceManager.events?.onReject(callId)
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        destroyCall()
    }

    // Respond to hold/unhold immediately — the OS holds our call when another
    // self-managed call takes focus; failing to answer times out and disconnects.
    override fun onHold() {
        setOnHold()
    }

    override fun onUnhold() {
        setActive()
    }

    override fun onDisconnect() {
        NexusCallNotification.cancel(context, callId)
        NexusVoiceManager.events?.onDisconnect(callId)
        NexusCallForegroundService.stop(context, callId)
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroyCall()
    }

    override fun onAbort() {
        onDisconnect()
    }

    /** Local hangup / remote-left originated from the app or media layer. */
    fun endFromApp() {
        NexusCallNotification.cancel(context, callId)
        NexusCallForegroundService.stop(context, callId)
        setDisconnected(DisconnectCause(DisconnectCause.REMOTE))
        destroyCall()
    }

    private fun destroyCall() {
        NexusVoiceManager.unregister(callId)
        destroy()
    }
}
