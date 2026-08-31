package net.inverge.nexus

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import net.inverge.nexus.core.NexusCrashReporter
import net.inverge.nexus.core.NexusNdk
import net.inverge.nexus.core.NexusReplayRecorder

/**
 * Flutter <-> Android bridge. Device/app context is served here; session-replay
 * capture is delegated to the native core SDK (`net.inverge.nexus.core`), which
 * pushes rrweb-compatible event batches back up over the `onReplayBatch` channel.
 */
class NexusPlugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private var recorder: NexusReplayRecorder? = null
    private var crashReporter: NexusCrashReporter? = null
    private var ndk: NexusNdk? = null

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
            else -> result.notImplemented()
        }
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
}
