package com.guardian.child

import android.accessibilityservice.AccessibilityService
import android.content.SharedPreferences
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject

/**
 * Accessibility service that monitors the URL bar across all supported browsers.
 *
 * Captured URLs are stored in a thread-safe in-memory queue.  MainActivity
 * calls [getPendingUrlsJson] (via the `getPendingBrowserUrls` method channel)
 * to drain the queue and return the entries as a JSON string, which the Dart
 * layer then uploads to Firestore under children/{childId}/browser_history/recent.
 */
class BrowserMonitorService : AccessibilityService() {

    companion object {
        private const val TAG = "BrowserMonitor"

        /** Live instance, used by [performHomeAction] so callers outside
         *  the service (MainActivity, MonitorService) can trigger the
         *  system HOME action without holding a context-bound reference. */
        @Volatile
        private var instance: BrowserMonitorService? = null

        private val BROWSER_PACKAGES = setOf(
            "com.android.chrome",
            "com.chrome.beta",
            "com.chrome.dev",
            "com.chrome.canary",
            "org.mozilla.firefox",
            "org.mozilla.firefox_beta",
            "com.opera.browser",
            "com.opera.mini.native",
            "com.microsoft.emmx",
            "com.brave.browser",
            "com.duckduckgo.mobile.android",
            "com.sec.android.app.sbrowser"
        )

        /** Last seen URL (for deduplication). */
        @Volatile
        var lastUrl: String = ""
            private set

        /** Pending URL entries waiting to be uploaded to Firestore. */
        private val pendingUrls: ArrayDeque<Map<String, Any>> = ArrayDeque()

        /**
         * Returns all pending URL entries as a JSON string and clears the queue.
         * Called from the `getPendingBrowserUrls` method channel on the main thread.
         */
        fun getPendingUrlsJson(): String {
            val snapshot: List<Map<String, Any>>
            synchronized(pendingUrls) {
                snapshot = pendingUrls.toList()
                pendingUrls.clear()
            }
            val arr = JSONArray()
            for (entry in snapshot) {
                val obj = JSONObject()
                obj.put("url",       entry["url"]         ?: "")
                obj.put("browser",   entry["packageName"] ?: "")
                obj.put("timestamp", entry["timestamp"]   ?: 0L)
                arr.put(obj)
            }
            return arr.toString()
        }

        /**
         * Presses the system HOME button via the accessibility framework.
         * This is used before launching the block screen so background media
         * (e.g. YouTube, Spotify) actually pauses instead of continuing to
         * play audio while the overlay is visible.
         *
         * Returns true if the action was dispatched, false if the
         * accessibility service isn't currently running.
         */
        fun performHomeAction(): Boolean {
            val svc = instance ?: return false
            return try {
                svc.performGlobalAction(GLOBAL_ACTION_HOME)
            } catch (e: Exception) {
                Log.e(TAG, "performHomeAction error", e)
                false
            }
        }
    }

    private var prefs: SharedPreferences? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        prefs = getSharedPreferences("browser_monitor", MODE_PRIVATE)
        Log.d(TAG, "BrowserMonitorService connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val packageName = event.packageName?.toString() ?: return
        if (packageName !in BROWSER_PACKAGES) return

        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED &&
            event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return

        try {
            val rootNode = rootInActiveWindow ?: return
            val url = extractUrl(rootNode)
            rootNode.recycle()

            if (url.isEmpty() || url == lastUrl) return
            lastUrl = url

            val entry = mapOf<String, Any>(
                "url"         to url,
                "packageName" to packageName,
                "timestamp"   to System.currentTimeMillis()
            )

            synchronized(pendingUrls) {
                pendingUrls.addLast(entry)
                // Keep at most 200 entries in the queue to cap memory use
                while (pendingUrls.size > 200) pendingUrls.removeFirst()
            }

            // Also persist the latest URL to SharedPreferences so it's readable
            // even if the method channel hasn't been called yet.
            prefs?.edit()
                ?.putString("last_url",     url)
                ?.putLong(  "last_url_time", System.currentTimeMillis())
                ?.putString("last_browser",  packageName)
                ?.apply()

            Log.d(TAG, "Browser URL: $url from $packageName")
        } catch (e: Exception) {
            Log.e(TAG, "Error reading browser URL", e)
        }
    }

    private fun extractUrl(node: AccessibilityNodeInfo): String {
        // Try known URL-bar view IDs for each browser. We keep a generous list
        // because Chrome has renamed the omnibox a few times, vendor forks
        // reuse different IDs, and Samsung Internet / Edge / Firefox all
        // diverge.
        val urlBarIds = listOf(
            // Chrome (stable + channels) — current and historical IDs
            "com.android.chrome:id/url_bar",
            "com.android.chrome:id/location_bar",
            "com.android.chrome:id/omnibox_text",
            "com.android.chrome:id/search_box_text",
            "com.chrome.beta:id/url_bar",
            "com.chrome.dev:id/url_bar",
            "com.chrome.canary:id/url_bar",
            // Firefox (Fenix / legacy)
            "org.mozilla.firefox:id/url_bar_title",
            "org.mozilla.firefox:id/mozac_browser_toolbar_url_view",
            "org.mozilla.firefox:id/mozac_browser_toolbar_background",
            "org.mozilla.firefox_beta:id/mozac_browser_toolbar_url_view",
            // Opera
            "com.opera.browser:id/url_field",
            "com.opera.mini.native:id/url_field",
            // Edge — same codebase as Chromium
            "com.microsoft.emmx:id/url_bar",
            "com.microsoft.emmx:id/location_bar",
            // Brave
            "com.brave.browser:id/url_bar",
            "com.brave.browser:id/location_bar",
            // DuckDuckGo
            "com.duckduckgo.mobile.android:id/omnibarTextInput",
            // Samsung Internet
            "com.sec.android.app.sbrowser:id/location_bar_edit_text",
            "com.sec.android.app.sbrowser:id/url_bar"
        )

        for (id in urlBarIds) {
            val nodes = node.findAccessibilityNodeInfosByViewId(id)
            if (!nodes.isNullOrEmpty()) {
                val text = nodes[0].text?.toString() ?: ""
                nodes.forEach { it.recycle() }
                if (text.isNotEmpty() && looksLikeUrl(text)) return text
            }
        }

        // Fallback: search the subtree for any EditText / TextView whose
        // contents look URL-shaped. Some browsers (e.g. DuckDuckGo on newer
        // builds) surface the URL in a plain TextView once the user leaves
        // the address bar.
        return findUrlInChildren(node)
    }

    /** Cheap heuristic — we do this both so the view-ID matcher ignores
     *  "placeholder" text like "Search or type URL" and so the subtree
     *  fallback doesn't mistake a page title for a URL. */
    private fun looksLikeUrl(text: String): Boolean {
        if (text.isBlank() || text.length < 4) return false
        if (text.contains(' ')) return false
        // Either has a scheme, or a dot with no whitespace (e.g. "example.com/foo")
        if (text.startsWith("http://") || text.startsWith("https://")) return true
        return text.contains('.')
    }

    private fun findUrlInChildren(node: AccessibilityNodeInfo): String {
        val cls = node.className?.toString() ?: ""
        if (cls == "android.widget.EditText" || cls == "android.widget.TextView") {
            val text = node.text?.toString() ?: ""
            if (looksLikeUrl(text)) return text
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val result = findUrlInChildren(child)
            child.recycle()
            if (result.isNotEmpty()) return result
        }
        return ""
    }

    override fun onInterrupt() {
        Log.d(TAG, "BrowserMonitorService interrupted")
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance === this) instance = null
        Log.d(TAG, "BrowserMonitorService destroyed")
    }
}
