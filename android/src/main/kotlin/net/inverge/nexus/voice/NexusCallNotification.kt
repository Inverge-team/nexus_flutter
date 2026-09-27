package net.inverge.nexus.voice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.drawable.Icon
import android.os.Build

/**
 * The visible incoming-call UI for a self-managed call. The OS does NOT draw one
 * for self-managed ConnectionServices, so we post it ourselves: a high-priority
 * CallStyle notification (Android 12+) that shows over the lock screen with
 * Answer / Decline — WITHOUT a full-screen activity, so the app never opens.
 */
object NexusCallNotification {
    private const val CHANNEL_ID = "nexus_incoming_call"
    private const val MISSED_CHANNEL_ID = "nexus_missed_call_v2"

    fun show(context: Context, callId: String, from: String, displayName: String?, avatarUrl: String? = null) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannel(nm)
        val name = displayName?.takeIf { it.isNotEmpty() } ?: from.ifEmpty { "Incoming call" }

        val answer = action(context, NexusCallActionReceiver.ACTION_ANSWER, callId, 1)
        val decline = action(context, NexusCallActionReceiver.ACTION_DECLINE, callId, 2)
        // Full-screen intent to our OWN native ring screen (over the lock screen),
        // NOT the Flutter app. Android REQUIRES CallStyle to carry one.
        val fullScreen = fullScreenIntent(context, callId, from, displayName, avatarUrl)

        // Post the ring IMMEDIATELY (name only) so an incoming call is never delayed
        // by a network fetch, then load the avatar off-thread and re-post with the
        // caller's photo when it arrives — only while the call is still ringing.
        postIncoming(context, nm, callId, name, fullScreen, answer, decline, null)
        if (!avatarUrl.isNullOrBlank() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Thread {
                val bmp = loadCircularBitmap(context, avatarUrl, 4000)
                val stillRinging = NexusVoiceManager.find(callId)?.state == android.telecom.Connection.STATE_RINGING
                if (bmp != null && stillRinging) {
                    postIncoming(context, nm, callId, name, fullScreen, answer, decline, bmp)
                }
            }.start()
        }
    }

    private fun postIncoming(
        context: Context,
        nm: NotificationManager,
        callId: String,
        name: String,
        fullScreen: PendingIntent,
        answer: PendingIntent,
        decline: PendingIntent,
        avatar: Bitmap?,
    ) {
        val builder = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle(name)
            .setContentText("Incoming call")
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setFullScreenIntent(fullScreen, true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder().setName(name).setImportant(true)
            if (avatar != null) person.setIcon(Icon.createWithBitmap(avatar))
            builder.setStyle(Notification.CallStyle.forIncomingCall(person.build(), decline, answer))
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

    private fun fullScreenIntent(
        context: Context,
        callId: String,
        from: String,
        name: String?,
        avatarUrl: String?,
    ): PendingIntent {
        val i = Intent(context, NexusIncomingCallActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION)
            .putExtra(NexusIncomingCallActivity.EXTRA_CALL_ID, callId)
            .putExtra(NexusIncomingCallActivity.EXTRA_FROM, from)
            .putExtra(NexusIncomingCallActivity.EXTRA_NAME, name)
            .putExtra(NexusIncomingCallActivity.EXTRA_AVATAR, avatarUrl)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) flags = flags or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(context, callId.hashCode() * 10 + 3, i, flags)
    }

    fun cancel(context: Context, callId: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(callId.hashCode())
    }

    /** Replace the (now-cancelled) ring with a "Missed call" notification — the
     *  caller hung up before we answered, exactly like a native missed call. */
    fun showMissed(context: Context, callId: String, from: String, displayName: String?, avatarUrl: String? = null) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureMissedChannel(nm)
        val name = displayName?.takeIf { it.isNotEmpty() } ?: from.ifEmpty { "Unknown caller" }
        // A missed call is not time-critical — a brief blocking fetch is fine here.
        val avatar =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) loadCircularBitmap(context, avatarUrl, 2500) else null

        // Tapping it opens the app (like tapping a native missed call).
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val tap = if (open != null) {
            var f = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) f = f or PendingIntent.FLAG_IMMUTABLE
            PendingIntent.getActivity(context, callId.hashCode() * 10 + 5, open, f)
        } else {
            null
        }

        val builder = Notification.Builder(context, MISSED_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_missed_call)
            .setContentTitle(name)
            .setContentText("Missed call")
            .setCategory(Notification.CATEGORY_MISSED_CALL)
            .setAutoCancel(true)
            .setShowWhen(true)
            .setWhen(System.currentTimeMillis())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // A Person makes Android render it with the caller's avatar/name — the
            // native missed-call look, not a plain text line.
            val caller = Person.Builder().setName(name)
            if (avatar != null) caller.setIcon(Icon.createWithBitmap(avatar))
            builder.addPerson(caller.build())
        }
        if (tap != null) builder.setContentIntent(tap)
        try {
            nm.notify(missedId(callId), builder.build())
            logMissed(context, "showMissed posted id=${missedId(callId)} name=$name channelBlocked=${channelBlocked(nm)}")
        } catch (t: Throwable) {
            logMissed(context, "showMissed FAILED: $t")
        }
    }

    private fun channelBlocked(nm: NotificationManager): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val ch = nm.getNotificationChannel(MISSED_CHANNEL_ID) ?: return false
        return ch.importance == NotificationManager.IMPORTANCE_NONE
    }

    private fun logMissed(context: Context, msg: String) {
        try {
            java.io.File(context.filesDir, "nexus_missed.log")
                .appendText("${System.currentTimeMillis()}  $msg\n")
        } catch (_: Throwable) {}
        android.util.Log.i("NexusVoice", msg)
    }

    private fun missedId(callId: String) = callId.hashCode() xor 0x4D495353 // "MISS"

    private fun ensureMissedChannel(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        // HIGH so OEMs (MIUI) actually surface it — a missed call should be seen.
        val ch = NotificationChannel(MISSED_CHANNEL_ID, "Missed calls", NotificationManager.IMPORTANCE_HIGH)
        ch.description = "Missed voice calls"
        ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        nm.createNotificationChannel(ch)
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

    /** Best-effort avatar download → circular bitmap. Returns null on any failure
     *  or timeout so the caller falls back to the name/initial. Blocks the calling
     *  thread — only call it off the main thread. Logs every outcome to
     *  `nexus_call.log` (pull with `run-as <pkg> cat files/nexus_call.log`) so a
     *  killed/locked-screen failure is diagnosable.
     *
     *  NB: unlike Flutter's NetworkImage, Android's HttpURLConnection BLOCKS
     *  cleartext (http://) on API 28+ — an http avatar URL fails here while it
     *  loads fine in the in-app overlay. Use https, or allow cleartext for the
     *  host in the app's network-security-config. */
    internal fun loadCircularBitmap(context: Context, url: String?, timeoutMs: Int): Bitmap? {
        if (url.isNullOrBlank()) {
            logCall(context, "avatar: no url — showing initial")
            return null
        }
        return try {
            var target = url
            var conn: java.net.HttpURLConnection
            var hops = 0
            while (true) {
                conn = (java.net.URL(target).openConnection() as java.net.HttpURLConnection).apply {
                    connectTimeout = timeoutMs
                    readTimeout = timeoutMs
                    instanceFollowRedirects = false // handle manually to allow http↔https redirects
                    setRequestProperty("User-Agent", "NexusVoice-Android")
                    setRequestProperty("Accept", "image/*")
                }
                val code = conn.responseCode
                if (code in 300..399 && hops < 4) {
                    val loc = conn.getHeaderField("Location")
                    conn.disconnect()
                    if (loc.isNullOrBlank()) {
                        logCall(context, "avatar: HTTP $code with no Location for $url")
                        return null
                    }
                    target = java.net.URL(java.net.URL(target), loc).toString()
                    hops++
                    continue
                }
                if (code != 200) {
                    logCall(context, "avatar: HTTP $code for $url")
                    conn.disconnect()
                    return null
                }
                break
            }
            val bytes = conn.inputStream.use { it.readBytes() }
            val bmp = decodeSampled(bytes, 256)
            if (bmp == null) {
                logCall(context, "avatar: decode failed (${bytes.size} bytes) for $url")
                return null
            }
            logCall(context, "avatar: OK ${bmp.width}x${bmp.height} for $url")
            circleCrop(bmp)
        } catch (t: Throwable) {
            logCall(context, "avatar: FAILED $url — ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }

    /** Decode a bitmap downsampled so its longest edge is ~[maxPx], to stay cheap
     *  and OOM-safe in the constrained process that a killed-app ring runs in. */
    private fun decodeSampled(bytes: ByteArray, maxPx: Int): Bitmap? {
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        val longest = maxOf(bounds.outWidth, bounds.outHeight)
        while (longest / sample > maxPx * 2) sample *= 2
        val opts = android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
        return android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
    }

    private fun logCall(context: Context, msg: String) {
        try {
            java.io.File(context.filesDir, "nexus_call.log")
                .appendText("${System.currentTimeMillis()}  $msg\n")
        } catch (_: Throwable) {}
        android.util.Log.i("NexusVoice", msg)
    }

    private fun circleCrop(src: Bitmap): Bitmap {
        val size = minOf(src.width, src.height)
        val squared =
            if (src.width != src.height) {
                Bitmap.createBitmap(src, (src.width - size) / 2, (src.height - size) / 2, size, size)
            } else {
                src
            }
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(output)
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
        val rect = android.graphics.Rect(0, 0, size, size)
        canvas.drawARGB(0, 0, 0, 0)
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        paint.xfermode = android.graphics.PorterDuffXfermode(android.graphics.PorterDuff.Mode.SRC_IN)
        canvas.drawBitmap(squared, rect, rect, paint)
        return output
    }
}
