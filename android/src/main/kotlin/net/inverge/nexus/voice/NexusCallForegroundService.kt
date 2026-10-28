package net.inverge.nexus.voice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugin.common.MethodChannel

/**
 * Foreground service that hosts a HEADLESS FlutterEngine to connect call media
 * (LiveKit) WITHOUT opening the app. Started from [NexusConnection.onAnswer].
 *
 * The engine runs the Dart entrypoint `nexusVoiceHeadlessMain` (see
 * voice_headless.dart). A private MethodChannel hands it the call id and relays
 * "call ended" back so we can stop the service. The service holds the
 * PHONE_CALL + MICROPHONE foreground types so the OS keeps the mic + process
 * alive for the whole call, exactly like a native dialer.
 */
class NexusCallForegroundService : Service() {

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var callId: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra(EXTRA_CALL_ID)
        val action = intent?.action
        android.util.Log.i(TAG, "onStartCommand action=$action id=$id")
        if (action == ACTION_STOP) {
            stopCall()
            return START_NOT_STICKY
        }
        if (id == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        callId = id
        try {
            startForegroundNotification()
            android.util.Log.i(TAG, "foreground notification up")
        } catch (t: Throwable) {
            android.util.Log.e(TAG, "startForeground FAILED: $t", t)
        }
        try {
            startHeadlessEngine(id)
        } catch (t: Throwable) {
            android.util.Log.e(TAG, "startHeadlessEngine FAILED: $t", t)
        }
        return START_NOT_STICKY
    }

    private fun startForegroundNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL_ID, "Ongoing call", NotificationManager.IMPORTANCE_LOW)
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Ongoing call")
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
            }
            startForeground(NOTIF_ID, notification, type)
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    /** Spin up a headless engine and run the call-media Dart entrypoint. */
    private fun startHeadlessEngine(id: String) {
        if (engine != null) return
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        val bundle = loader.findAppBundlePath()
        android.util.Log.i(TAG, "startHeadlessEngine call=$id bundle=$bundle")

        val eng = FlutterEngine(applicationContext)
        val ch = MethodChannel(eng.dartExecutor.binaryMessenger, CHANNEL_NAME)
        ch.setMethodCallHandler { call, result ->
            android.util.Log.i(TAG, "headless channel ${call.method}")
            when (call.method) {
                // Dart booted and is ready — give it the call to connect.
                "ready" -> result.success(callId)
                // Media connected or ended — reflect into Telecom + stop service.
                "callEnded" -> {
                    val cid = call.argument<String>("callId") ?: callId
                    if (cid != null) NexusVoiceManager.find(cid)?.endFromApp()
                    stopCall()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        eng.dartExecutor.executeDartEntrypoint(
            DartEntrypoint(bundle, "nexusVoiceHeadlessMain"),
        )
        android.util.Log.i(TAG, "headless entrypoint executed")
        engine = eng
        channel = ch
    }

    private fun stopCall() {
        try {
            channel?.invokeMethod("disconnect", null)
        } catch (_: Throwable) {}
        engine?.destroy()
        engine = null
        channel = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        engine?.destroy()
        engine = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "NexusVoiceFgs"
        private const val CHANNEL_ID = "nexus_call"
        private const val CHANNEL_NAME = "nexus/voice_headless"
        private const val NOTIF_ID = 0xC411
        private const val EXTRA_CALL_ID = "callId"
        private const val ACTION_STOP = "net.inverge.nexus.voice.STOP"

        fun start(context: Context, callId: String) {
            val i = Intent(context, NexusCallForegroundService::class.java)
                .putExtra(EXTRA_CALL_ID, callId)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun stop(context: Context, callId: String) {
            val i = Intent(context, NexusCallForegroundService::class.java)
                .setAction(ACTION_STOP)
                .putExtra(EXTRA_CALL_ID, callId)
            context.startService(i)
        }
    }
}
