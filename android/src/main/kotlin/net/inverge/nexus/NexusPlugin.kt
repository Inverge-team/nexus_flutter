package net.inverge.nexus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
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

    /** Build and post a notification using the Android framework (no libraries). */
    private fun showNotification(call: MethodCall, result: Result) {
        val ctx = appContext
        if (ctx == null) {
            result.success(false)
            return
        }
        try {
            val title = call.argument<String>("title")
            val body = call.argument<String>("body")
            val channelId = call.argument<String>("channelId") ?: "nexus_default"
            val channelName = call.argument<String>("channelName") ?: "Notifications"
            val payload = call.argument<String>("payload")
            val id = call.argument<Int>("id") ?: (System.currentTimeMillis() and 0x7fffffff).toInt()

            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                nm.getNotificationChannel(channelId) == null
            ) {
                nm.createNotificationChannel(
                    NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_HIGH),
                )
            }

            // Tapping relaunches the app carrying the payload so Dart can attribute the open.
            val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                putExtra(EXTRA_PAYLOAD, payload)
            }
            var piFlags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) piFlags = piFlags or PendingIntent.FLAG_IMMUTABLE
            val contentIntent = launch?.let { PendingIntent.getActivity(ctx, id, it, piFlags) }

            val smallIcon = if (ctx.applicationInfo.icon != 0) {
                ctx.applicationInfo.icon
            } else {
                android.R.drawable.ic_dialog_info
            }

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(ctx, channelId)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(ctx).setPriority(Notification.PRIORITY_HIGH)
            }
            builder.setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(smallIcon)
                .setAutoCancel(true)
            if (body != null) builder.setStyle(Notification.BigTextStyle().bigText(body))
            if (contentIntent != null) builder.setContentIntent(contentIntent)

            nm.notify(id, builder.build())
            result.success(true)
        } catch (_: Throwable) {
            result.success(false) // never let a notification failure break the channel
        }
    }

    override fun onNewIntent(intent: Intent): Boolean {
        val payload = intent.getStringExtra(EXTRA_PAYLOAD) ?: return false
        intent.removeExtra(EXTRA_PAYLOAD) // consume so it fires once
        main.post { channel.invokeMethod("onNotificationTap", payload) }
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
        channel.setMethodCallHandler(null)
    }

    private companion object {
        const val EXTRA_PAYLOAD = "net.inverge.nexus.NOTIFICATION_PAYLOAD"
    }
}
