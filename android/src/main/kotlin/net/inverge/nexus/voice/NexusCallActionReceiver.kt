package net.inverge.nexus.voice

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Handles taps on the incoming-call notification's Answer / Decline actions.
 * Runs WITHOUT opening the app — it drives the native [NexusConnection] directly,
 * which (on answer) starts the headless media service. This is what makes the
 * call behave like a normal phone call: answer straight from the notification.
 */
class NexusCallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: return
        val conn = NexusVoiceManager.find(callId)
        when (intent.action) {
            ACTION_ANSWER -> conn?.onAnswer()
            ACTION_DECLINE -> conn?.onReject()
        }
        NexusCallNotification.cancel(context, callId)
    }

    companion object {
        const val ACTION_ANSWER = "net.inverge.nexus.voice.ANSWER"
        const val ACTION_DECLINE = "net.inverge.nexus.voice.DECLINE"
        const val EXTRA_CALL_ID = "callId"
    }
}
