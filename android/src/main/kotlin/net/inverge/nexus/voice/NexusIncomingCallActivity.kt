package net.inverge.nexus.voice

import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import net.inverge.nexus.R

/**
 * The native incoming-call screen shown over the lock screen (full-screen intent
 * target). Fully self-contained, professionally styled — gradient backdrop,
 * caller avatar with animated ring pulse, and circular Answer / Decline actions.
 * It is NOT the Flutter app; answering drives the connection natively.
 */
class NexusIncomingCallActivity : Activity() {

    private var callId: String = ""
    private val animators = mutableListOf<ValueAnimator>()

    // Palette
    private val bgTop = 0xFF12263F.toInt()
    private val bgBottom = 0xFF060B14.toInt()
    private val white = 0xFFFFFFFF.toInt()
    private val muted = 0xFF9DB0C6.toInt()
    private val faint = 0xFF6B7C93.toInt()
    private val answerGreen = 0xFF2FBF71.toInt()
    private val declineRed = 0xFFF04438.toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreen()
        edgeToEdge()

        callId = intent.getStringExtra(EXTRA_CALL_ID).orEmpty()
        val from = intent.getStringExtra(EXTRA_FROM).orEmpty()
        val name = (intent.getStringExtra(EXTRA_NAME)?.takeIf { it.isNotBlank() }
            ?: from.takeIf { it.isNotBlank() } ?: "Unknown caller")

        current = this
        setContentView(buildUi(name))
    }

    override fun onDestroy() {
        animators.forEach { it.cancel() }
        animators.clear()
        if (current === this) current = null
        super.onDestroy()
    }

    // ── UI ──────────────────────────────────────────────────────────────────

    private fun buildUi(name: String): FrameLayout {
        val root = FrameLayout(this).apply {
            background = GradientDrawable(
                GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(bgTop, bgBottom),
            )
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            clipChildren = false
            clipToPadding = false
        }

        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(64), dp(28), dp(48))
            layoutParams = FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            clipChildren = false
            clipToPadding = false
        }

        // Top eyebrow label
        col.addView(TextView(this).apply {
            text = "INCOMING CALL"
            setTextColor(faint)
            textSize = 13f
            letterSpacing = 0.28f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
        })

        col.addView(spacer(weight = 1.15f))

        // Avatar with pulsing rings
        col.addView(buildAvatar(name))

        col.addView(gap(dp(30)))

        // Caller name
        col.addView(TextView(this).apply {
            text = name
            setTextColor(white)
            textSize = 30f
            letterSpacing = 0.01f
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        })

        // Subtitle: the host app's name (the app using the Nexus SDK).
        col.addView(TextView(this).apply {
            text = appName()
            setTextColor(muted)
            textSize = 15f
            letterSpacing = 0.03f
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, 0)
        })

        col.addView(spacer(weight = 2f))

        // Actions row
        col.addView(buildActions())

        root.addView(col)
        return root
    }

    private fun buildAvatar(name: String): FrameLayout {
        val box = dp(210)
        val stack = FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(box, box).apply {
                gravity = Gravity.CENTER_HORIZONTAL
            }
        }
        // Pulsing rings behind the avatar
        val ringSizes = intArrayOf(dp(210), dp(178), dp(148))
        ringSizes.forEachIndexed { i, size ->
            val ring = View(this).apply {
                background = ovalStroke(0x33FFFFFF, dp(1))
                layoutParams = FrameLayout.LayoutParams(size, size, Gravity.CENTER)
                alpha = 0f
            }
            stack.addView(ring)
            pulse(ring, delay = (i * 520).toLong())
        }

        // Avatar circle with the caller's initial + a colour derived from the name
        val avatarSize = dp(118)
        val (c1, c2) = avatarColors(name)
        val avatar = TextView(this).apply {
            text = initialOf(name)
            setTextColor(white)
            textSize = 46f
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            gravity = Gravity.CENTER
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(c1, c2),
            ).apply { shape = GradientDrawable.OVAL }
            layoutParams = FrameLayout.LayoutParams(avatarSize, avatarSize, Gravity.CENTER)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) elevation = dp(10).toFloat()
        }
        stack.addView(avatar)
        return stack
    }

    private fun buildActions(): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT)
            clipChildren = false
            clipToPadding = false
        }
        row.addView(actionButton("Decline", declineRed, R.drawable.nexus_ic_call_end) { decline() })
        row.addView(spacer(weight = 1f, horizontal = true))
        val answer = actionButton("Answer", answerGreen, R.drawable.nexus_ic_call) { answer() }
        row.addView(answer)
        // Gently pulse the answer button to invite the tap.
        (answer.getChildAt(0))?.let { breathe(it) }
        return row
    }

    /** A vertical [circular icon button + label] column. */
    private fun actionButton(
        label: String,
        color: Int,
        iconRes: Int,
        onClick: () -> Unit,
    ): LinearLayout {
        val size = dp(72)
        val button = FrameLayout(this).apply {
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(color) }
            layoutParams = LinearLayout.LayoutParams(size, size).apply { gravity = Gravity.CENTER_HORIZONTAL }
            isClickable = true
            isFocusable = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) elevation = dp(8).toFloat()
            setOnClickListener { onClick() }
        }
        val icon = ImageView(this).apply {
            setImageResource(iconRes)
            val d = dp(30)
            layoutParams = FrameLayout.LayoutParams(d, d, Gravity.CENTER)
        }
        button.addView(icon)

        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT)
            clipChildren = false
            clipToPadding = false
            addView(button)
            addView(TextView(context).apply {
                text = label
                setTextColor(muted)
                textSize = 13f
                letterSpacing = 0.02f
                gravity = Gravity.CENTER
                setPadding(0, dp(12), 0, 0)
            })
        }
    }

    // ── Animations ─────────────────────────────────────────────────────────

    private fun pulse(v: View, delay: Long) {
        val a = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 2100
            startDelay = delay
            repeatCount = ValueAnimator.INFINITE
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener {
                val t = it.animatedValue as Float
                val scale = 0.72f + 0.42f * t
                v.scaleX = scale
                v.scaleY = scale
                v.alpha = (1f - t) * 0.55f
            }
        }
        animators.add(a)
        a.start()
    }

    private fun breathe(v: View) {
        val a = ObjectAnimator.ofFloat(v, "scaleX", 1f, 1.12f).apply {
            duration = 900
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            interpolator = AccelerateDecelerateInterpolator()
        }
        val b = ObjectAnimator.ofFloat(v, "scaleY", 1f, 1.12f).apply {
            duration = 900
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            interpolator = AccelerateDecelerateInterpolator()
        }
        animators.add(a); animators.add(b)
        a.start(); b.start()
    }

    // ── Actions ────────────────────────────────────────────────────────────

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

    // ── Window / helpers ─────────────────────────────────────────────────────

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

    @Suppress("DEPRECATION")
    private fun edgeToEdge() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            window.statusBarColor = Color.TRANSPARENT
            window.navigationBarColor = Color.TRANSPARENT
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun spacer(weight: Float, horizontal: Boolean = false): View = View(this).apply {
        layoutParams = if (horizontal) {
            LinearLayout.LayoutParams(0, WRAP_CONTENT, weight)
        } else {
            LinearLayout.LayoutParams(MATCH_PARENT, 0, weight)
        }
    }

    private fun gap(px: Int): View = View(this).apply {
        layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, px)
    }

    private fun ovalStroke(color: Int, width: Int): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(Color.TRANSPARENT)
        setStroke(width, color)
    }

    /** The host app's display name (the app embedding the Nexus SDK). */
    private fun appName(): String = try {
        packageManager.getApplicationLabel(applicationInfo).toString()
    } catch (_: Throwable) {
        ""
    }

    private fun initialOf(name: String): String {
        val ch = name.trim().firstOrNull { it.isLetterOrDigit() }
        return (ch?.uppercaseChar() ?: '?').toString()
    }

    /** A pleasant, deterministic two-tone gradient derived from the caller name. */
    private fun avatarColors(name: String): Pair<Int, Int> {
        val hue = ((name.hashCode() % 360) + 360) % 360
        val c1 = Color.HSVToColor(floatArrayOf(hue.toFloat(), 0.55f, 0.72f))
        val c2 = Color.HSVToColor(floatArrayOf(((hue + 28) % 360).toFloat(), 0.62f, 0.46f))
        return c1 to c2
    }

    companion object {
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
