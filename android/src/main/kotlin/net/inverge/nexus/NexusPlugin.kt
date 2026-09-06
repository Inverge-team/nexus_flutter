package net.inverge.nexus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
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
            "showNotification" -> showNotification(call, result)
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

    private fun resolveSmallIcon(ctx: Context, name: String?): Int {
        val byName = resolveDrawable(ctx, name)
        if (byName != 0) return byName
        return if (ctx.applicationInfo.icon != 0) ctx.applicationInfo.icon else android.R.drawable.ic_dialog_info
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

    override fun onNewIntent(intent: Intent): Boolean {
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
    }
}
