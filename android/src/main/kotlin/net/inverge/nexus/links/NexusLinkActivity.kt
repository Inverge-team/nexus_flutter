package net.inverge.nexus.links

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Trampoline for Nexus App Links (`https://<link host>/a/<applicationId>/<slug>`).
 *
 * A plugin cannot add an intent filter to the app's own launcher activity, so
 * the SDK declares the verified (`autoVerify`) filter on this invisible activity
 * instead and forwards the URL to the app's launcher activity as an EXTRA — not
 * as intent data. Flutter only routes intent data, so the app's router never
 * sees `/a/…/<slug>` (a path it has no route for); the plugin picks the extra up
 * and the SDK routes to the link's deep-link value instead.
 */
class NexusLinkActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent?.data?.toString()
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (url != null && launch != null) {
            // CLEAR_TOP + SINGLE_TOP: a running app gets onNewIntent on its
            // existing activity instead of a second copy.
            launch.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP,
            )
            launch.putExtra(EXTRA_LINK, url)
            startActivity(launch)
        }
        finish()
    }

    companion object {
        /** The forwarded link URL, read (and removed) by the plugin. */
        const val EXTRA_LINK = "net.inverge.nexus.LINK"
    }
}
