package net.inverge.nexus.voice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * The visible incoming-call UI for a self-managed call. The OS does NOT draw one
 * for self-managed ConnectionServices, so we post it ourselves: a high-priority
 * CallStyle notification (Android 12+) that shows over the lock screen with
 * Answer / Decline — WITHOUT a full-screen activity, so the app never opens.
 */
object NexusCallNotification {
    private const val CHANNEL_ID = "nexus_incoming_call"

    fun show(context: Context, callId: String, from: String, displayName: String?) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannel(nm)
        val name = displayName?.takeIf { it.isNotEmpty() } ?: from.ifEmpty { "Incoming call" }

        val answer = action(context, NexusCallActionReceiver.ACTION_ANSWER, callId, 1)
        val decline = action(context, NexusCallActionReceiver.ACTION_DECLINE, callId, 2)
        // Full-screen intent to our OWN native ring screen (over the lock screen),
        // NOT the Flutter app. Android REQUIRES CallStyle to carry one.
        val fullScreen = fullScreenIntent(context, callId, from, displayName)

        val builder = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle(name)
            .setContentText("Incoming call")
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setFullScreenIntent(fullScreen, true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val caller = Person.Builder().setName(name).setImportant(true).build()
            builder.setStyle(Notification.CallStyle.forIncomingCall(caller, decline, answer))
        } else {
            // Pre-12: prominent heads-up with explicit Answer/Decline actions.
            builder.setPriority(Notification.PRIORITY_MAX)
            builder.addAction(android.R.drawable.sym_action_call, "Answer", answer)
            builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "Decline", decline)
        }
        // Never let a notification failure crash the app (some OEMs are strict).
        try {
            nm.notify(callId.hashCode(), builder.build())
        } catch (t: Throwable) {
            android.util.Log.w("NexusVoice", "incoming notification failed: ${t.message}")
        }
    }

    private fun fullScreenIntent(context: Context, callId: String, from: String, name: String?): PendingIntent {
        val i = Intent(context, NexusIncomingCallActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION)
            .putExtra(NexusIncomingCallActivity.EXTRA_CALL_ID, callId)
            .putExtra(NexusIncomingCallActivity.EXTRA_FROM, from)
            .putExtra(NexusIncomingCallActivity.EXTRA_NAME, name)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) flags = flags or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(context, callId.hashCode() * 10 + 3, i, flags)
    }

    fun cancel(context: Context, callId: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(callId.hashCode())
    }

    private fun action(context: Context, act: String, callId: String, req: Int): PendingIntent {
        val i = Intent(context, NexusCallActionReceiver::class.java)
            .setAction(act)
            .putExtra(NexusCallActionReceiver.EXTRA_CALL_ID, callId)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) flags = flags or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(context, callId.hashCode() * 10 + req, i, flags)
    }

    private fun ensureChannel(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val ch = NotificationChannel(CHANNEL_ID, "Incoming calls", NotificationManager.IMPORTANCE_HIGH)
        ch.description = "Incoming voice calls"
        ch.setShowBadge(false)
        ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        nm.createNotificationChannel(ch)
    }
}
