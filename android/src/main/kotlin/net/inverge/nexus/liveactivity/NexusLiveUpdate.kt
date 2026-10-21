package net.inverge.nexus.liveactivity

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.Icon
import android.os.Build
import org.json.JSONObject

/**
 * Renders a Nexus Live Activity template as an Android notification — the same
 * JSON the iOS widget renders. Android 16+ (API 36): a promoted **Live Update**
 * with `ProgressStyle` (one segment per step gap, a point per step, the tracker
 * icon riding the bar, a status chip, an ETA countdown). Older Android: an
 * ongoing notification with a progress bar.
 *
 * Payload: `{ event: start|update|end, activityId, template, data }` where data
 * is `{ step, state, progress, etaAt, values, title?, subtitle?, body? }`.
 * Runs on a background thread (images are downloaded).
 */
internal object NexusLiveUpdate {
    private const val CHANNEL_ID = "nexus_live"
    private const val CHANNEL_NAME = "Live activities"
    // Notification.EXTRA_REQUEST_PROMOTED_ONGOING (API 36.1); NotificationCompat uses the same key.
    private const val EXTRA_REQUEST_PROMOTED_ONGOING = "android.requestPromotedOngoing"
    private const val STEP_LEN = 100

    // Template image URLs are immutable (uploads get a fresh name), so a small
    // in-process cache spares re-downloading the tracker on every update.
    private val bitmaps = object : LinkedHashMap<String, Bitmap>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Bitmap>?) = size > 12
    }

    private fun cachedBitmap(url: String, loadBitmap: (String) -> Bitmap?): Bitmap? {
        synchronized(bitmaps) { bitmaps[url]?.let { return it } }
        val bmp = loadBitmap(url)?.let { scaled(it) } ?: return null
        synchronized(bitmaps) { bitmaps[url] = bmp }
        return bmp
    }

    fun show(
        ctx: Context,
        id: Int,
        payloadJson: String,
        smallIcon: Int,
        contentIntent: PendingIntent?,
        loadBitmap: (String) -> Bitmap?,
    ): Boolean {
        val payload = JSONObject(payloadJson)
        val tpl = payload.optJSONObject("template") ?: JSONObject()
        val data = payload.optJSONObject("data") ?: JSONObject()
        val m = Model(tpl, data)
        val ending = payload.optString("event") == "end"
        val ongoing = !ending && !m.isCanceled && !m.isDone

        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_DEFAULT))
        }
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(ctx, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(ctx)
        }
        b.setSmallIcon(smallIcon)
            .setContentTitle(m.title ?: "")
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setOnlyAlertOnce(true) // updates must not buzz
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(contentIntent)
        (m.subtitle ?: m.body)?.let { b.setContentText(it) }
        m.color(m.theme?.optString("brand"))?.let { b.setColor(it) } // accent only — never colorized (blocks promotion)

        // ETA countdown in the header.
        m.etaMillis?.let {
            b.setWhen(it).setShowWhen(true).setUsesChronometer(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) b.setChronometerCountDown(true)
        }

        if (Build.VERSION.SDK_INT >= 36) {
            applyProgressStyle(ctx, b, m, loadBitmap)
            m.chipText?.let { b.setShortCriticalText(it) }
            if (ongoing) b.extras.putBoolean(EXTRA_REQUEST_PROMOTED_ONGOING, true)
        } else {
            if (m.layout != "text") b.setProgress(100, (m.overallProgress * 100).toInt().coerceIn(0, 100), false)
            m.chipText?.let { b.setSubText(it) }
        }

        nm.notify(id, b.build())
        return true
    }

    private fun applyProgressStyle(ctx: Context, b: Notification.Builder, m: Model, loadBitmap: (String) -> Bitmap?) {
        if (m.layout == "text") return
        val accent = m.color(m.theme?.optString("accent")) ?: Color.parseColor("#10B981")
        val danger = m.color(m.theme?.optString("danger")) ?: Color.parseColor("#EF4444")
        val style = Notification.ProgressStyle().setStyledByProgress(true)
        val n = m.stepCount
        if (m.layout == "steps" && n >= 2) {
            // n-1 equal segments with a point at every step.
            for (i in 0 until n - 1) style.addProgressSegment(Notification.ProgressStyle.Segment(STEP_LEN).setColor(if (m.isCanceled) danger else accent))
            for (i in 0 until n) style.addProgressPoint(Notification.ProgressStyle.Point(i * STEP_LEN).setColor(if (m.isCanceled) danger else accent))
            style.setProgress(if (m.isCanceled) 0 else (m.trackerSlot * STEP_LEN).toInt())
        } else {
            style.addProgressSegment(Notification.ProgressStyle.Segment(STEP_LEN).setColor(accent))
            style.setProgress((m.barProgress * STEP_LEN).toInt())
        }
        if (!m.isCanceled) icon(ctx, m.trackerRef, loadBitmap)?.let { style.setProgressTrackerIcon(it) }
        icon(ctx, m.tpl.optJSONObject("startIcon"), loadBitmap)?.let { style.setProgressStartIcon(it) }
        icon(ctx, m.tpl.optJSONObject("endIcon"), loadBitmap)?.let { style.setProgressEndIcon(it) }
        b.setStyle(style)
    }

    /** ImageRef → Icon: `url` (downloaded) → `res` (app drawable). SF Symbols are iOS-only. */
    private fun icon(ctx: Context, ref: JSONObject?, loadBitmap: (String) -> Bitmap?): Icon? {
        if (ref == null) return null
        ref.optString("url").takeIf { it.startsWith("https://") }?.let { url ->
            cachedBitmap(url, loadBitmap)?.let { return Icon.createWithBitmap(it) }
        }
        ref.optString("res").takeIf { it.isNotBlank() }?.let { name ->
            val rid = ctx.resources.getIdentifier(name, "drawable", ctx.packageName)
            if (rid != 0) return Icon.createWithResource(ctx, rid)
        }
        return null
    }

    private fun scaled(bmp: Bitmap, max: Int = 192): Bitmap {
        val longest = maxOf(bmp.width, bmp.height)
        if (longest <= max) return bmp
        val f = max.toFloat() / longest
        return Bitmap.createScaledBitmap(bmp, (bmp.width * f).toInt().coerceAtLeast(1), (bmp.height * f).toInt().coerceAtLeast(1), true)
    }

    /** Mirrors the iOS renderer's model (NexusLAModel) so both platforms agree. */
    private class Model(val tpl: JSONObject, val data: JSONObject) {
        val steps = tpl.optJSONArray("steps")?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }.filter { it.optString("id").isNotBlank() }
        } ?: emptyList()
        val stepCount get() = steps.size
        val theme: JSONObject? = tpl.optJSONObject("theme")
        val layout: String = when (tpl.optString("layout").lowercase()) {
            "steps" -> if (steps.size >= 2) "steps" else "progress"
            "text" -> "text"
            "progress" -> "progress"
            else -> if (steps.size >= 2) "steps" else "progress"
        }
        private val stateKey = norm(data.optString("state"))
        val isCanceled = stateKey.startsWith("cancel")
        val stepIndex: Int = run {
            val wanted = norm(data.optString("step"))
            val found = if (wanted.isEmpty()) -1 else steps.indexOfFirst { norm(it.optString("id")) == wanted || norm(it.optString("label")) == wanted }
            when {
                found >= 0 -> found
                stateKey == "done" || stateKey == "completed" -> (steps.size - 1).coerceAtLeast(0)
                else -> 0
            }
        }
        private val progress: Double? = fraction(data.opt("progress"))
        val isDone = !isCanceled && (stateKey == "done" || stateKey == "completed" ||
            (layout == "steps" && stepIndex == steps.size - 1) || (layout == "progress" && (progress ?: 0.0) >= 1.0))
        val current: JSONObject? = steps.getOrNull(stepIndex)

        val trackerSlot: Double get() {
            val last = (steps.size - 1).coerceAtLeast(0).toDouble()
            if (isDone) return last
            val p = progress ?: 0.0
            return minOf(last, stepIndex + if (stepIndex < steps.size - 1) p else 0.0)
        }
        val barProgress: Double get() = if (isDone) 1.0 else progress ?: 0.0
        val overallProgress: Double get() =
            if (layout == "steps" && steps.isNotEmpty()) (if (isDone) 1.0 else trackerSlot / (steps.size - 1).coerceAtLeast(1)) else barProgress

        private val values: Map<String, String> = buildMap {
            data.optJSONObject("values")?.let { v -> v.keys().forEach { k -> put(k, v.opt(k)?.toString() ?: "") } }
            if (!containsKey("step")) current?.optString("label")?.takeIf { it.isNotBlank() }?.let { put("step", it) }
        }

        val title: String? get() = str(data, "title") ?: when {
            isCanceled -> resolve(tpl.optJSONObject("canceled")?.let { str(it, "title") }) ?: "Canceled"
            else -> resolve(current?.let { str(it, "title") }) ?: resolve(str(tpl, "title"))
        }
        val subtitle: String? get() = str(data, "subtitle") ?: resolve(current?.let { str(it, "subtitle") }) ?: resolve(str(tpl, "subtitle"))
        val body: String? get() = str(data, "body") ?: resolve(current?.let { str(it, "body") }) ?: resolve(str(tpl, "body"))

        // showEta=false is a master switch; otherwise a step's own setting decides (default on).
        private val etaAllowed: Boolean get() = !isCanceled && !isDone && tpl.optBoolean("showEta", true) &&
            (current?.takeIf { it.has("eta") }?.optBoolean("eta") ?: true)
        val etaMillis: Long? get() {
            if (!etaAllowed) return null
            val t = (data.opt("etaAt") as? Number)?.toDouble() ?: data.optString("etaAt").toDoubleOrNull() ?: return null
            val ms = (t * 1000).toLong()
            return if (ms > System.currentTimeMillis()) ms else null
        }
        /** Status chip: the ETA text while driving, else the current step's label. */
        val chipText: String? get() = when {
            isCanceled -> tpl.optJSONObject("canceled")?.let { str(it, "label") } ?: "Canceled"
            etaAllowed && values["eta"]?.isNotBlank() == true -> values["eta"]
            else -> current?.let { str(it, "label") }
        }?.take(7) // Android shows ~7 characters in the chip

        val trackerRef: JSONObject? get() =
            if (tpl.optString("dir").equals("rtl", true)) tpl.optJSONObject("trackerRtl") ?: tpl.optJSONObject("tracker")
            else tpl.optJSONObject("tracker")

        fun color(hex: String?): Int? {
            if (hex.isNullOrBlank()) return null
            var s = hex.trim().removePrefix("#")
            if (s.length == 8) s = s.substring(6) + s.substring(0, 6) // RRGGBBAA → AARRGGBB
            return try { Color.parseColor("#$s") } catch (_: Throwable) { null }
        }

        private val placeholder = Regex("\\{\\{\\s*([A-Za-z0-9_.-]+)\\s*\\}\\}")
        fun resolve(text: String?): String? {
            if (text.isNullOrBlank()) return null
            var s = placeholder.replace(text) { values[it.groupValues[1]] ?: "" }
            s = s.replace(Regex("·\\s*·"), "·").trim { it.isWhitespace() || it in "·•|,-–—" }
            return s.ifBlank { null }
        }

        companion object {
            fun norm(s: String): String = s.lowercase().filter { it.isLetterOrDigit() }
            fun str(o: JSONObject, k: String): String? = if (o.has(k) && !o.isNull(k)) o.optString(k).takeIf { it.isNotBlank() } else null
            fun fraction(v: Any?): Double? {
                val d = (v as? Number)?.toDouble() ?: (v as? String)?.toDoubleOrNull() ?: return null
                return (if (d > 1) d / 100 else d).coerceIn(0.0, 1.0)
            }
        }
    }
}
