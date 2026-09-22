package net.inverge.nexus.voice

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import androidx.annotation.RequiresApi

/**
 * Self-built voice call control — NO third-party call libraries. Owns the Android
 * Telecom integration so incoming calls ring in the SYSTEM call UI and are
 * answered NATIVELY (in [NexusConnection.onAnswer]) WITHOUT launching the Flutter
 * app. This is the WhatsApp model: the OS shows the call, our own foreground
 * service brings up the media, and the app UI is never forced open.
 *
 * Flow:
 *   FCM push -> [reportIncomingCall] -> TelecomManager.addNewIncomingCall
 *     -> [NexusConnectionService.onCreateIncomingConnection] -> [NexusConnection]
 *     -> system rings -> user answers -> [NexusConnection.onAnswer] (no app open)
 *     -> [NexusCallForegroundService] -> headless media connect.
 */
object NexusVoiceManager {
    /** Telecom self-managed PhoneAccount id. One per app. */
    private const val ACCOUNT_ID = "nexus_voice"

    /** Bridges native call events (answer/reject/disconnect) up to Dart. Set by
     *  the plugin when the engine attaches; may be null when the app is killed
     *  and only the ConnectionService process is alive (answer still works — the
     *  foreground service drives the media without Dart on the UI side). */
    @Volatile
    var events: NexusCallEvents? = null

    /** Live connections keyed by our call id (sessionId), so Dart-side hangup /
     *  remote-end can drive the matching native [Connection]. */
    private val connections = HashMap<String, NexusConnection>()

    fun phoneAccountHandle(context: Context): PhoneAccountHandle =
        PhoneAccountHandle(
            ComponentName(context, NexusConnectionService::class.java),
            ACCOUNT_ID,
        )

    /** Register (idempotently) a self-managed PhoneAccount so Telecom will route
     *  our incoming calls through [NexusConnectionService]. */
    @RequiresApi(Build.VERSION_CODES.O)
    fun registerPhoneAccount(context: Context) {
        val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        val handle = phoneAccountHandle(context)
        val account = PhoneAccount.builder(handle, "Nexus")
            .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
            .build()
        tm.registerPhoneAccount(account)
    }

    /** Ask Telecom to show the system incoming-call UI for [callId]. Safe from a
     *  background/killed context — Telecom owns the process lifetime. */
    @RequiresApi(Build.VERSION_CODES.O)
    fun reportIncomingCall(
        context: Context,
        callId: String,
        fromHandle: String,
        displayName: String?,
        hasVideo: Boolean,
    ) {
        val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        val handle = phoneAccountHandle(context)
        val extras = Bundle().apply {
            putParcelable(
                TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                Uri.fromParts("nexus", fromHandle.ifEmpty { callId }, null),
            )
            putBundle(
                TelecomManager.EXTRA_INCOMING_CALL_EXTRAS,
                Bundle().apply {
                    putString(EXTRA_CALL_ID, callId)
                    putString(EXTRA_FROM, fromHandle)
                    putString(EXTRA_DISPLAY_NAME, displayName)
                    putBoolean(EXTRA_HAS_VIDEO, hasVideo)
                },
            )
        }
        tm.addNewIncomingCall(handle, extras)
    }

    internal fun register(callId: String, connection: NexusConnection) {
        connections[callId] = connection
    }

    internal fun unregister(callId: String) {
        connections.remove(callId)
    }

    fun find(callId: String): NexusConnection? = connections[callId]

    /** End a call from the Dart side (local hangup) or because the remote left. */
    fun endCall(callId: String) {
        connections[callId]?.endFromApp()
    }

    /** The caller cancelled while we were still ringing — end the ring as MISSED
     *  and leave a "Missed call" notification, like a native phone call. */
    fun missedCall(context: Context, callId: String, from: String, displayName: String?) {
        connections[callId]?.markMissed()
        // Also cancel the ring directly — a killed-app cancel push may arrive with
        // no tracked connection, but the ring notification must still clear.
        NexusCallNotification.cancel(context, callId)
        NexusCallNotification.showMissed(context, callId, from, displayName)
    }

    /** Bring the app to the foreground and tell it to answer [callId] in the main
     *  Flutter engine (the proven LiveKit path). Works from a killed/locked state:
     *  the launch intent carries the call id, which the plugin reads on attach. */
    fun answerInApp(context: Context, callId: String) {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        if (launch != null) {
            // EXCLUDE_FROM_RECENTS: when the app is opened BY answering a call
            // (killed/locked), keep it out of the recent-apps panel so the call
            // doesn't leave the app parked there like the user launched it.
            launch.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS,
            )
            launch.putExtra(EXTRA_ANSWER_CALL_ID, callId)
            try {
                context.startActivity(launch)
            } catch (t: Throwable) {
                android.util.Log.e("NexusVoice", "answerInApp launch failed: $t", t)
            }
        }
    }

    const val EXTRA_CALL_ID = "nexus.callId"
    const val EXTRA_FROM = "nexus.from"
    const val EXTRA_DISPLAY_NAME = "nexus.displayName"
    const val EXTRA_HAS_VIDEO = "nexus.hasVideo"

    /** Launch-intent extra carrying the call id the app should auto-answer. */
    const val EXTRA_ANSWER_CALL_ID = "nexus.answerCallId"
}

/** Native -> Dart call event sink. Implemented by the plugin. */
interface NexusCallEvents {
    fun onAnswer(callId: String)
    fun onReject(callId: String)
    fun onDisconnect(callId: String)
}
