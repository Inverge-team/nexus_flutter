package net.inverge.nexus.voice

import android.os.Build
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import androidx.annotation.RequiresApi

/**
 * Self-managed Telecom [ConnectionService]. Android instantiates this (in the
 * app process, but WITHOUT launching an Activity) when we call
 * `TelecomManager.addNewIncomingCall`, and asks us to build a [Connection] for
 * the call. Returning a self-managed connection makes the SYSTEM draw the
 * incoming-call UI over the lock screen — the app UI stays closed.
 */
@RequiresApi(Build.VERSION_CODES.O)
class NexusConnectionService : ConnectionService() {

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection {
        val extras = request?.extras?.getBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS)
        val callId = extras?.getString(NexusVoiceManager.EXTRA_CALL_ID).orEmpty()
        val from = extras?.getString(NexusVoiceManager.EXTRA_FROM).orEmpty()
        val name = extras?.getString(NexusVoiceManager.EXTRA_DISPLAY_NAME)
        val hasVideo = extras?.getBoolean(NexusVoiceManager.EXTRA_HAS_VIDEO) ?: false

        val connection = NexusConnection(applicationContext, callId, from, name)
        connection.setAddress(request?.address, TelecomManager.PRESENTATION_ALLOWED)
        connection.setCallerDisplayName(
            name ?: from.ifEmpty { "Incoming call" },
            TelecomManager.PRESENTATION_ALLOWED,
        )
        connection.connectionCapabilities = Connection.CAPABILITY_MUTE or
            Connection.CAPABILITY_SUPPORT_HOLD or
            Connection.CAPABILITY_HOLD
        connection.audioModeIsVoip = true
        connection.videoState = if (hasVideo) {
            android.telecom.VideoProfile.STATE_BIDIRECTIONAL
        } else {
            android.telecom.VideoProfile.STATE_AUDIO_ONLY
        }
        connection.setRinging()
        // The OS draws NO UI for self-managed calls — present our own now so the
        // user actually sees the incoming call (over the lock screen).
        connection.presentIncomingUi()

        if (callId.isNotEmpty()) NexusVoiceManager.register(callId, connection)
        return connection
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        val extras = request?.extras?.getBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS)
        val callId = extras?.getString(NexusVoiceManager.EXTRA_CALL_ID).orEmpty()
        if (callId.isNotEmpty()) {
            NexusVoiceManager.events?.onReject(callId)
            NexusVoiceManager.unregister(callId)
        }
    }
}
