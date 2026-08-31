package net.inverge.nexus

import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import net.inverge.nexus.core.NexusCrashReporter
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
    private var recorder: NexusReplayRecorder? = null
    private var crashReporter: NexusCrashReporter? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "nexus")
        channel.setMethodCallHandler(this)
        crashReporter = NexusCrashReporter(binding.applicationContext)
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
            "deviceInfo" -> result.success(
                mapOf(
                    "osType" to "android",
                    "osVersion" to Build.VERSION.RELEASE,
                    "deviceModel" to "${Build.MANUFACTURER} ${Build.MODEL}",
                    "deviceKey" to null,
                ),
            )
            "startReplay" -> {
                recorder?.start(call.argument<String>("recordingId") ?: "")
                result.success(null)
            }
            "stopReplay" -> {
                recorder?.stop()
                result.success(null)
            }
            "configureCrashReporting" -> {
                if (call.argument<Boolean>("enabled") == true) crashReporter?.install()
                result.success(null)
            }
            "takePendingCrashes" -> result.success(crashReporter?.takePending() ?: emptyList<Any>())
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        recorder?.stop()
        recorder = null
        channel.setMethodCallHandler(null)
    }
}
