package net.inverge.nexus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import org.json.JSONObject
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import net.inverge.nexus.core.NexusCrashReporter
import net.inverge.nexus.core.NexusNdk
import net.inverge.nexus.core.NexusReplayRecorder
import net.inverge.nexus.links.NexusLinkActivity
import net.inverge.nexus.liveactivity.NexusLiveUpdate
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener

/**
 * Flutter <-> Android bridge. Device/app context is served here; session-replay
 * capture is delegated to the native core SDK (`net.inverge.nexus.core`), which
 * pushes rrweb-compatible event batches back up over the `onReplayBatch` channel.
 *
 * Also renders foreground push notifications natively (`showNotification`) — FCM
 * never draws one while the app is open — and forwards taps back to Dart
 * (`onNotificationTap`) so the open can be attributed. No third-party libraries.
 */
class NexusPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener {
    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private var recorder: NexusReplayRecorder? = null
    private var crashReporter: NexusCrashReporter? = null
    private var ndk: NexusNdk? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val io = Executors.newSingleThreadExecutor() // notification image downloads

    // Deep links seen before Dart asked for them (cold start), then live.
    private val pendingLinks = ArrayList<String>()
    private var linksLive = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "nexus")
        channel.setMethodCallHandler(this)
        appContext = binding.applicationContext
        crashReporter = NexusCrashReporter(binding.applicationContext)
        ndk = NexusNdk(binding.applicationContext)
        recorder = NexusReplayRecorder(binding.applicationContext) { recordingId, events ->
            // Marshal batches back to Dart on the platform thread.
            main.post {
                channel.invokeMethod(
                    "onReplayBatch",
                    mapOf("recordingId" to recordingId, "events" to events),
                )
            }
        }
        // Bridge native Telecom call events (answer/reject/disconnect handled in
        // the ConnectionService WITHOUT opening the app) up to the Dart voice
        // layer when the UI engine is alive.
        net.inverge.nexus.voice.NexusVoiceManager.events =
            object : net.inverge.nexus.voice.NexusCallEvents {
                override fun onAnswer(callId: String) = emitCall("onCallAnswer", callId)
                override fun onReject(callId: String) = emitCall("onCallReject", callId)
                override fun onDisconnect(callId: String) = emitCall("onCallDisconnect", callId)
            }
    }

    private fun emitCall(method: String, callId: String) {
        main.post { channel.invokeMethod(method, mapOf("callId" to callId)) }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${Build.VERSION.RELEASE}")
            "deviceInfo" -> result.success(deviceInfo())
            "startReplay" -> {
                recorder?.start(call.argument<String>("recordingId") ?: "")
                result.success(null)
            }
            "stopReplay" -> {
                recorder?.stop()
                result.success(null)
            }
            "configureCrashReporting" -> {
                if (call.argument<Boolean>("enabled") == true) {
                    crashReporter?.install() // JVM (Java/Kotlin) uncaught exceptions
                    ndk?.install() // native (NDK) C/C++ signal crashes
                }
                result.success(null)
            }
            "takePendingCrashes" -> {
                val all = ArrayList<Any>()
                crashReporter?.takePending()?.let { all.addAll(it) }
                ndk?.takePending()?.let { all.addAll(it) }
                result.success(all)
            }
            "voiceRegisterAccount" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    appContext?.let { net.inverge.nexus.voice.NexusVoiceManager.registerPhoneAccount(it) }
                }
                result.success(null)
            }
            "voiceReportIncoming" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    appContext?.let {
                        net.inverge.nexus.voice.NexusVoiceManager.reportIncomingCall(
                            it,
                            call.argument<String>("callId") ?: "",
                            call.argument<String>("from") ?: "",
                            call.argument<String>("displayName"),
                            call.argument<String>("avatarUrl"),
                            call.argument<Boolean>("hasVideo") ?: false,
                        )
                    }
                }
                result.success(null)
            }
            "voiceEndCall" -> {
                call.argument<String>("callId")?.let {
                    net.inverge.nexus.voice.NexusVoiceManager.endCall(it)
                }
                result.success(null)
            }
            "voiceMissedCall" -> {
                appContext?.let { ctx ->
                    call.argument<String>("callId")?.let {
                        net.inverge.nexus.voice.NexusVoiceManager.missedCall(
                            ctx, it, call.argument<String>("from") ?: "", call.argument<String>("displayName"),
                            call.argument<String>("avatarUrl"),
                        )
                    }
                }
                result.success(null)
            }
            "linksTakePending" -> {
                result.success(ArrayList(pendingLinks))
                pendingLinks.clear()
                linksLive = true
            }
            "linksConfigure" -> {
                val hosts = call.argument<List<String>>("hosts") ?: emptyList()
                appContext?.getSharedPreferences(LINK_PREFS, Context.MODE_PRIVATE)?.edit()
                    ?.putStringSet(LINK_HOSTS, hosts.map { it.lowercase() }.toSet())?.apply()
                result.success(null)
            }
            "installReferrer" -> installReferrer(result)
            "showNotification" -> showNotification(call, result)
            "showLiveActivity" -> showLiveActivity(call, result)
            "showLiveActivityTemplate" -> showLiveActivityTemplate(call, result)
            "endLiveActivity" -> {
                val id = call.argument<Int>("id")
                if (id != null) {
                    (appContext?.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)?.cancel(id)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Build and post a notification using the Android framework (no libraries).
     * Runs on a background executor because large-icon / big-picture images may
     * need to be downloaded; [result] is answered once the notification is posted.
     */
    private fun showNotification(call: MethodCall, result: Result) {
        val ctx = appContext
        if (ctx == null) {
            result.success(false)
            return
        }
        val title = call.argument<String>("title")
        val body = call.argument<String>("body")
        val channelId = call.argument<String>("channelId") ?: "nexus_default"
        val channelName = call.argument<String>("channelName") ?: "Notifications"
        val payload = call.argument<String>("payload")
        val id = call.argument<Int>("id") ?: (System.currentTimeMillis() and 0x7fffffff).toInt()
        val largeIconUrl = call.argument<String>("largeIcon")
        val bigPictureUrl = call.argument<String>("bigPicture")
        val smallIconName = call.argument<String>("smallIcon")
        val visibility = call.argument<String>("visibility")
        val accentColor = call.argument<String>("accentColor")
        val buttons = call.argument<List<Map<String, Any?>>>("buttons") ?: emptyList()

        io.execute {
            try {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    nm.getNotificationChannel(channelId) == null
                ) {
                    nm.createNotificationChannel(
                        NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_HIGH),
                    )
                }

                val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Notification.Builder(ctx, channelId)
                } else {
                    @Suppress("DEPRECATION")
                    Notification.Builder(ctx).setPriority(Notification.PRIORITY_HIGH)
                }
                builder.setContentTitle(title)
                    .setContentText(body)
                    .setSmallIcon(resolveSmallIcon(ctx, smallIconName))
                    .setAutoCancel(true)
                    .setContentIntent(activityIntent(ctx, id, payload, null, null))

                // Lockscreen visibility.
                builder.setVisibility(
                    when (visibility) {
                        "private" -> Notification.VISIBILITY_PRIVATE
                        "secret" -> Notification.VISIBILITY_SECRET
                        else -> Notification.VISIBILITY_PUBLIC
                    },
                )
                if (accentColor != null) {
                    try {
                        builder.setColor(Color.parseColor(accentColor)); @Suppress("DEPRECATION") builder.setColorized(true)
                    } catch (_: Throwable) { /* invalid colour — ignore */ }
                }
                if (largeIconUrl != null) bitmapFromUrl(largeIconUrl)?.let { builder.setLargeIcon(it) }

                // Big-picture (expanded) style, else BigText so long bodies expand.
                val bigPicture = bigPictureUrl?.let { bitmapFromUrl(it) }
                if (bigPicture != null) {
                    builder.setStyle(Notification.BigPictureStyle().bigPicture(bigPicture))
                } else if (body != null) {
                    builder.setStyle(Notification.BigTextStyle().bigText(body))
                }

                // Action buttons — each relaunches the app carrying its id + url.
                buttons.forEachIndexed { i, b ->
                    val bid = b["id"]?.toString() ?: return@forEachIndexed
                    val text = b["text"]?.toString() ?: return@forEachIndexed
                    val actionIcon = resolveDrawable(ctx, b["icon"]?.toString())
                    val pi = activityIntent(ctx, id * 8 + i + 1, payload, bid, b["url"]?.toString())
                    @Suppress("DEPRECATION")
                    builder.addAction(actionIcon, text, pi)
                }

                nm.notify(id, builder.build())
                main.post { result.success(true) }
            } catch (_: Throwable) {
                main.post { result.success(false) } // never break the channel
            }
        }
    }

    /**
     * Post/update an Android live ongoing notification — the Android equivalent
     * of an iOS Live Activity. An updating ongoing notification with an optional
     * progress bar; on Android 16+ it is styled as a promoted Live Update.
     */
    private fun showLiveActivity(call: MethodCall, result: Result) {
        val ctx = appContext ?: return result.success(false)
        try {
            val id = call.argument<Int>("id") ?: return result.success(false)
            val channelId = call.argument<String>("channelId") ?: "nexus_live"
            val channelName = call.argument<String>("channelName") ?: "Live activities"
            val title = call.argument<String>("title")
            val body = call.argument<String>("body")
            val subText = call.argument<String>("subText")
            val progress = call.argument<Int>("progress")
            val indeterminate = call.argument<Boolean>("indeterminate") ?: false
            val ongoing = call.argument<Boolean>("ongoing") ?: true
            val payload = call.argument<String>("payload")

            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                nm.getNotificationChannel(channelId) == null
            ) {
                nm.createNotificationChannel(
                    NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_DEFAULT),
                )
            }

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(ctx, channelId)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(ctx)
            }
            builder.setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(resolveSmallIcon(ctx, null))
                .setOngoing(ongoing)
                .setOnlyAlertOnce(true) // updates shouldn't buzz each time
                .setContentIntent(activityIntent(ctx, id, payload, null, null))
            if (subText != null) builder.setSubText(subText)
            if (indeterminate) {
                builder.setProgress(0, 0, true)
            } else if (progress != null) {
                builder.setProgress(100, progress.coerceIn(0, 100), false)
            }

            nm.notify(id, builder.build())
            result.success(true)
        } catch (_: Throwable) {
            result.success(false)
        }
    }

    /** Render a Nexus Live Activity template (Android 16 Live Update / progress fallback). */
    private fun showLiveActivityTemplate(call: MethodCall, result: Result) {
        val ctx = appContext ?: return result.success(false)
        val id = call.argument<Int>("id") ?: return result.success(false)
        val payload = call.argument<String>("payload") ?: return result.success(false)
        io.execute {
            val ok = try {
                NexusLiveUpdate.show(ctx, id, payload, resolveSmallIcon(ctx, null), activityIntent(ctx, id, payload, null, null)) { bitmapFromUrl(it) }
            } catch (_: Throwable) {
                false
            }
            main.post { result.success(ok) }
        }
    }

    /** A PendingIntent that relaunches the app with the payload (+ optional action). */
    private fun activityIntent(ctx: Context, requestCode: Int, payload: String?, actionId: String?, url: String?): PendingIntent? {
        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra(EXTRA_PAYLOAD, payload)
            if (actionId != null) putExtra(EXTRA_ACTION_ID, actionId)
            if (url != null) putExtra(EXTRA_ACTION_URL, url)
        } ?: return null
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) flags = flags or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(ctx, requestCode, launch, flags)
    }

    /**
     * The small icon, in the order FCM itself resolves one: the campaign's own
     * drawable, then the app's `default_notification_icon` manifest meta-data,
     * then the conventional `ic_stat_notification`/`ic_notification` drawable.
     * The launcher icon is the last resort only — Android masks a small icon by
     * its alpha channel, so a full-colour launcher icon draws as a blank square.
     */
    private fun resolveSmallIcon(ctx: Context, name: String?): Int {
        resolveDrawable(ctx, name).let { if (it != 0) return it }
        manifestNotificationIcon(ctx).let { if (it != 0) return it }
        for (conventional in arrayOf("ic_stat_notification", "ic_notification")) {
            resolveDrawable(ctx, conventional).let { if (it != 0) return it }
        }
        return if (ctx.applicationInfo.icon != 0) ctx.applicationInfo.icon else android.R.drawable.ic_dialog_info
    }

    /** `com.google.firebase.messaging.default_notification_icon` from the manifest, or 0. */
    private fun manifestNotificationIcon(ctx: Context): Int = try {
        ctx.packageManager
            .getApplicationInfo(ctx.packageName, PackageManager.GET_META_DATA)
            .metaData
            ?.getInt("com.google.firebase.messaging.default_notification_icon", 0)
            ?: 0
    } catch (_: Throwable) {
        0
    }

    private fun resolveDrawable(ctx: Context, name: String?): Int {
        if (name.isNullOrBlank()) return 0
        return ctx.resources.getIdentifier(name, "drawable", ctx.packageName)
    }

    private fun bitmapFromUrl(url: String): Bitmap? {
        return try {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 8000
            conn.readTimeout = 8000
            conn.doInput = true
            conn.connect()
            conn.inputStream.use { BitmapFactory.decodeStream(it) }
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Capture a deep link from an activity intent for the Dart links service.
     *
     * Runs BEFORE Flutter reads the intent (plugins are attached in onAttach,
     * ahead of the initial route; on onNewIntent plugins are told first), so a
     * Nexus SHORT link can be consumed here — data cleared — and the app's router
     * never receives `/l/<slug>`, a path it has no route for. Any other link is
     * left for the router and only reported.
     */
    private fun captureLink(intent: Intent?) {
        if (intent == null) return
        intent.getStringExtra(NexusLinkActivity.EXTRA_LINK)?.let { url ->
            intent.removeExtra(NexusLinkActivity.EXTRA_LINK)
            deliverLink(url)
            return
        }
        if (intent.action != Intent.ACTION_VIEW) return
        val data = intent.data ?: return
        // A config-change re-attach replays the same intent — report it once.
        if (intent.getBooleanExtra(EXTRA_LINK_SEEN, false)) return
        intent.putExtra(EXTRA_LINK_SEEN, true)
        val url = data.toString()
        if (isShortLink(data)) intent.data = null
        deliverLink(url)
    }

    private fun deliverLink(url: String) {
        if (linksLive) {
            main.post { channel.invokeMethod("onLinkOpened", url) }
        } else {
            pendingLinks.add(url)
        }
    }

    /** `/l/<slug>` or `/a/<appId>/<slug>` on a Nexus link host. */
    private fun isShortLink(uri: android.net.Uri): Boolean {
        val host = uri.host?.lowercase() ?: return false
        val hosts = appContext?.getSharedPreferences(LINK_PREFS, Context.MODE_PRIVATE)
            ?.getStringSet(LINK_HOSTS, null) ?: emptySet()
        if (host != DEFAULT_LINK_HOST && host !in hosts) return false
        val s = uri.pathSegments.filter { it.isNotEmpty() }
        return (s.size == 2 && s[0] == "l") || (s.size == 3 && s[0] == "a")
    }

    /** Google Play's install referrer string, or null (not from Play / unavailable). */
    private fun installReferrer(result: Result) {
        val ctx = appContext ?: return result.success(null)
        val client = try {
            InstallReferrerClient.newBuilder(ctx).build()
        } catch (_: Throwable) {
            return result.success(null)
        }
        var answered = false
        fun answer(value: String?) {
            if (answered) return
            answered = true
            main.post { result.success(value) }
            try { client.endConnection() } catch (_: Throwable) {}
        }
        try {
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(code: Int) {
                    if (code == InstallReferrerClient.InstallReferrerResponse.OK) {
                        answer(try { client.installReferrer.installReferrer } catch (_: Throwable) { null })
                    } else {
                        answer(null)
                    }
                }

                override fun onInstallReferrerServiceDisconnected() = answer(null)
            })
        } catch (_: Throwable) {
            answer(null)
        }
    }

    override fun onNewIntent(intent: Intent): Boolean {
        captureLink(intent)
        maybeForwardAnswer(intent)
        val payload = intent.getStringExtra(EXTRA_PAYLOAD)
        val actionId = intent.getStringExtra(EXTRA_ACTION_ID)
        if (payload == null && actionId == null) return false
        val map = HashMap<String, Any?>()
        if (payload != null) {
            try {
                val obj = JSONObject(payload)
                for (key in obj.keys()) map[key] = obj.get(key)
            } catch (_: Throwable) { /* not JSON — forward action only */ }
        }
        if (actionId != null) map["nexus_action_id"] = actionId
        intent.getStringExtra(EXTRA_ACTION_URL)?.let { map["nexus_action_url"] = it }
        intent.removeExtra(EXTRA_PAYLOAD) // consume so it fires once
        intent.removeExtra(EXTRA_ACTION_ID)
        intent.removeExtra(EXTRA_ACTION_URL)
        main.post { channel.invokeMethod("onNotificationTap", map) }
        return false
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        // Launched from a deep link (cold start) — capture it before Flutter
        // reads the intent for its initial route.
        captureLink(binding.activity.intent)
        // The app may have been launched by answering a native call — forward it.
        maybeForwardAnswer(binding.activity.intent)
    }

    /** If this intent carries a native "answer this call" request, tell Dart to
     *  answer it in the main engine (the proven media path). Consumes the extra. */
    private fun maybeForwardAnswer(intent: Intent?) {
        val callId = intent?.getStringExtra(net.inverge.nexus.voice.NexusVoiceManager.EXTRA_ANSWER_CALL_ID)
            ?: return
        intent.removeExtra(net.inverge.nexus.voice.NexusVoiceManager.EXTRA_ANSWER_CALL_ID)
        main.post { channel.invokeMethod("onCallAnswer", mapOf("callId" to callId)) }
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    private fun deviceInfo(): Map<String, Any?> {
        val info = mutableMapOf<String, Any?>(
            "osType" to "android",
            "osVersion" to Build.VERSION.RELEASE,
            "deviceModel" to "${Build.MANUFACTURER} ${Build.MODEL}",
        )
        val ctx = appContext ?: return info
        try {
            val pm = ctx.packageManager
            val pkg = ctx.packageName
            @Suppress("DEPRECATION")
            val pInfo = pm.getPackageInfo(pkg, 0)
            info["installTime"] = pInfo.firstInstallTime // epoch ms
            info["updateTime"] = pInfo.lastUpdateTime
            info["installerStore"] = if (Build.VERSION.SDK_INT >= 30) {
                pm.getInstallSourceInfo(pkg).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                pm.getInstallerPackageName(pkg)
            }
        } catch (_: Throwable) {
            // best-effort — never fail the channel call
        }
        return info
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        recorder?.stop()
        recorder = null
        appContext = null
        io.shutdown()
        channel.setMethodCallHandler(null)
    }

    private companion object {
        const val EXTRA_PAYLOAD = "net.inverge.nexus.NOTIFICATION_PAYLOAD"
        const val EXTRA_ACTION_ID = "net.inverge.nexus.NOTIFICATION_ACTION_ID"
        const val EXTRA_ACTION_URL = "net.inverge.nexus.NOTIFICATION_ACTION_URL"
        const val EXTRA_LINK_SEEN = "net.inverge.nexus.LINK_SEEN"
        const val LINK_PREFS = "nexus_links"
        const val LINK_HOSTS = "hosts"
        const val DEFAULT_LINK_HOST = "services.inverge.net"
    }
}
