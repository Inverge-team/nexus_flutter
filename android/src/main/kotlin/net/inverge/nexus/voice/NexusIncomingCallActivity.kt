package net.inverge.nexus.voice

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Lightweight, self-contained incoming-call screen used ONLY as the full-screen
 * intent target for the call notification (Android requires CallStyle to have
 * one). It shows over the lock screen with Answer / Decline and is NOT the
 * Flutter app — answering connects media headlessly and finishes, so the app UI
 * is never opened. This is the WhatsApp-style native ring screen.
 */
class NexusIncomingCallActivity : Activity() {

    private var callId: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreen()

        callId = intent.getStringExtra(EXTRA_CALL_ID).orEmpty()
        val name = intent.getStringExtra(EXTRA_NAME)
            ?: intent.getStringExtra(EXTRA_FROM).orEmpty().ifEmpty { "Incoming call" }

        current = this // so a remote cancel can close this lock-screen ring screen
        setContentView(buildUi(name))
    }

    override fun onDestroy() {
        if (current === this) current = null
        super.onDestroy()
    }

    private fun buildUi(name: String): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#0B1221"))
            setPadding(48, 96, 48, 96)
            layoutParams = ViewGroup.LayoutParams(MATCH, MATCH)
        }
        root.addView(TextView(this).apply {
            text = name
            setTextColor(Color.WHITE)
            textSize = 28f
            gravity = Gravity.CENTER
        })
        root.addView(TextView(this).apply {
            text = "Incoming call"
            setTextColor(Color.parseColor("#9AA6B2"))
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(0, 16, 0, 96)
        })
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        row.addView(Button(this).apply {
            text = "Decline"
            setBackgroundColor(Color.parseColor("#E53935"))
            setTextColor(Color.WHITE)
            setOnClickListener { decline() }
        })
        row.addView(Button(this).apply {
            text = "Answer"
            setBackgroundColor(Color.parseColor("#43A047"))
            setTextColor(Color.WHITE)
            setPadding(48, 0, 0, 0)
            setOnClickListener { answer() }
        })
        root.addView(row)
        return root
    }

    private fun answer() {
        NexusCallNotification.cancel(this, callId)
        NexusVoiceManager.find(callId)?.onAnswer()
        finishAndRemoveTask()
    }

    private fun decline() {
        NexusCallNotification.cancel(this, callId)
        NexusVoiceManager.find(callId)?.onReject()
        finishAndRemoveTask()
    }

    @Suppress("DEPRECATION")
    private fun showOverLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            (getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)
                ?.requestDismissKeyguard(this, null)
        } else {
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            )
        }
    }

    companion object {
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val EXTRA_CALL_ID = "callId"
        const val EXTRA_FROM = "from"
        const val EXTRA_NAME = "name"

        /** The ring screen currently shown, if any (e.g. over the lock screen). */
        private var current: NexusIncomingCallActivity? = null

        /** Close the lock-screen ring screen for [callId] — the caller cancelled
         *  or the call ended remotely, so it must not keep ringing. */
        fun finishFor(callId: String) {
            val a = current ?: return
            if (a.callId == callId) a.runOnUiThread { a.finishAndRemoveTask() }
        }
    }
}
