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
    }

    private var prefs: SharedPreferences? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        prefs = getSharedPreferences("browser_monitor", MODE_PRIVATE)
        // Reset the dedup guard so we re-capture the current URL after a restart
        lastUrl = ""
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
        // Try known URL-bar view IDs for each browser
        val urlBarIds = listOf(
            "com.android.chrome:id/url_bar",
            "com.android.chrome:id/omnibox_text",
            "org.mozilla.firefox:id/url_bar_title",
            "org.mozilla.firefox:id/mozac_browser_toolbar_url_view",
            "com.opera.browser:id/url_field",
            "com.microsoft.emmx:id/url_bar",
            "com.brave.browser:id/url_bar",
            "com.sec.android.app.sbrowser:id/location_bar_edit_text"
        )

        for (id in urlBarIds) {
            val nodes = node.findAccessibilityNodeInfosByViewId(id)
            if (!nodes.isNullOrEmpty()) {
                val text = nodes[0].text?.toString() ?: ""
                nodes.forEach { it.recycle() }
                if (text.isNotEmpty()) return text
            }
        }

        // Fallback: search for an EditText node whose content looks like a URL
        return findUrlInChildren(node)
    }

    private fun findUrlInChildren(node: AccessibilityNodeInfo): String {
        if (node.className?.toString() == "android.widget.EditText") {
            val text = node.text?.toString() ?: ""
            if (text.contains(".") && !text.contains(" ") && text.length > 3) {
                return text
            }
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
        Log.d(TAG, "BrowserMonitorService destroyed")
    }
}
