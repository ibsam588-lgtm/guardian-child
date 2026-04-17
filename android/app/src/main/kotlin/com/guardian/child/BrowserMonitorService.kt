package com.guardian.child

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.google.firebase.FirebaseApp
import com.google.firebase.Timestamp
import com.google.firebase.firestore.FirebaseFirestore
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

        /**
         * Start an activity via the accessibility service's context.
         * Accessibility services are exempt from the API 29+ background
         * activity-launch restriction, so this is the reliable way to bring
         * `AppBlockedActivity` to the foreground while the child is inside
         * a blocked app. Returns true on success, false if the service
         * isn't currently connected or the start fails (caller should
         * fall back to a full-screen-intent notification).
         */
        fun startActivitySafely(intent: Intent): Boolean {
            val svc = instance ?: return false
            return try {
                svc.startActivity(intent)
                true
            } catch (e: Exception) {
                Log.w(TAG, "startActivitySafely failed: ${e.message}")
                false
            }
        }
    }

    private var prefs: SharedPreferences? = null

    // ── Diagnostics ────────────────────────────────────────────────────────
    // We write a status doc to children/{childId}/browser_history/status so
    // the parent can tell the difference between:
    //   (a) service not running at all (no doc)
    //   (b) service running but no browser events arriving (eventsSeen == 0)
    //   (c) events arriving but URL extraction failing (eventsSeen > 0, urlsCaptured == 0)
    //   (d) everything working (urlsCaptured > 0)
    private var eventsSeen: Long = 0
    private var urlsCaptured: Long = 0
    private var lastBrowserPkg: String = ""
    private var lastEventTs: Long = 0
    private var lastExtractSample: String = ""
    private var lastStatusWriteTs: Long = 0

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        prefs = getSharedPreferences("browser_monitor", MODE_PRIVATE)
        // Reset the dedup guard so we re-capture the current URL after a restart
        lastUrl = ""
        // Ensure Firebase is initialized in this process before any Firestore access.
        // The FirebaseInitProvider content-provider normally handles this automatically,
        // but accessibility services can be bound before the provider has run on some
        // devices/OEMs, so we guard here explicitly.
        try {
            FirebaseApp.getInstance()
        } catch (_: IllegalStateException) {
            try {
                FirebaseApp.initializeApp(applicationContext)
            } catch (e: Exception) {
                Log.w(TAG, "Firebase init failed: ${e.message}")
            }
        }
        Log.d(TAG, "BrowserMonitorService connected")
        // Emit an initial "connected" status so the parent UI immediately
        // sees the service is up, even before the child opens a browser.
        writeDiagnosticStatus(force = true, note = "connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val packageName = event.packageName?.toString() ?: return
        if (packageName !in BROWSER_PACKAGES) return

        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED &&
            event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return

        eventsSeen += 1
        lastBrowserPkg = packageName
        lastEventTs = System.currentTimeMillis()

        try {
            val rootNode = rootInActiveWindow
            if (rootNode == null) {
                writeDiagnosticStatus(note = "rootInActiveWindow=null")
                return
            }
            val url = extractUrl(rootNode)
            if (url.isEmpty()) {
                // Sample first EditText text we can find so the parent can tell
                // whether the URL bar is just showing placeholder text vs. the
                // extraction not finding the node at all.
                lastExtractSample = sampleAnyEditText(rootNode)
            }
            rootNode.recycle()

            if (url.isEmpty() || url == lastUrl) {
                writeDiagnosticStatus()
                return
            }
            lastUrl = url
            urlsCaptured += 1

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

            // Write directly to Firestore so history is synced even when the
            // Flutter app is not running (e.g. the user swiped it from recents
            // and the Dart polling timers are no longer firing).
            writeUrlToFirestore(url, packageName)

            writeDiagnosticStatus(force = true)
        } catch (e: Exception) {
            Log.e(TAG, "Error reading browser URL", e)
            writeDiagnosticStatus(note = "err:${e.javaClass.simpleName}")
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /** Reads the paired child's ID from the Flutter SharedPreferences file.
     *  Returns null if the device is not yet paired or prefs are inaccessible. */
    private fun getChildId(): String? {
        return try {
            val sp = applicationContext.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE)
            sp.getString("flutter.paired_child_id", null)?.takeIf { it.isNotBlank() }
        } catch (_: Exception) { null }
    }

    /**
     * Writes the captured URL directly to children/{childId}/browser_history/recent
     * so history syncs to Firestore even when the Flutter engine is not running.
     *
     * Uses a read-modify-write cycle (fire-and-forget) to append to the entries
     * array and keep it capped at 100 items.
     */
    private fun writeUrlToFirestore(url: String, packageName: String) {
        val childId = getChildId() ?: return

        // Guard against FirebaseApp not being initialised. BrowserMonitor
        // can fire before FirebaseInitProvider has run on some OEMs after
        // a cold boot — calling FirebaseFirestore.getInstance() before
        // init throws IllegalStateException and crashes the accessibility
        // service.
        try { FirebaseApp.getInstance() } catch (_: IllegalStateException) {
            try { FirebaseApp.initializeApp(applicationContext) } catch (e: Exception) {
                Log.w(TAG, "writeUrlToFirestore: Firebase init failed: ${e.message}")
                return
            }
        }

        // Each visit is its own document so we don't race against ourselves
        // on concurrent writes (the old append-to-array path had a get/set
        // window where fast navigations could clobber each other, leaving
        // only the last URL visible to the parent). Using a subcollection
        // also lets us order, filter, and TTL-expire with native Firestore
        // queries.
        val searchQuery = extractSearchQuery(url)
        val entry = hashMapOf<String, Any>(
            "url"       to url,
            "browser"   to packageName,
            "visitedAt" to Timestamp.now(),
        )
        if (searchQuery.isNotEmpty()) {
            entry["searchQuery"] = searchQuery
            entry["searchEngine"] = detectSearchEngine(url)
        }

        val col = FirebaseFirestore.getInstance()
            .collection("children")
            .document(childId)
            .collection("browser_history")

        col.add(entry)
            .addOnFailureListener { e ->
                Log.w(TAG, "browser_history add failed: ${e.message}")
            }

        // Keep the legacy /recent doc pointing at the most recent URL too,
        // so any older parent-app build that still reads the single-doc
        // shape doesn't regress to empty while the new build rolls out.
        // The array on /recent is no longer relied on by the parent UI.
        val recentRef = col.document("recent")
        recentRef.set(hashMapOf<String, Any>(
            "lastUrl"      to url,
            "lastBrowser"  to packageName,
            "updatedAt"    to Timestamp.now(),
        ), com.google.firebase.firestore.SetOptions.merge())
            .addOnFailureListener { e ->
                Log.w(TAG, "browser_history /recent merge failed: ${e.message}")
            }
    }

    /**
     * Pulls the user's query out of a known search-engine URL. Returns an
     * empty string if the URL isn't a recognised search. We extract this on
     * the child so the parent UI can surface "searched for: 'foo'" without
     * having to parse URLs in the client.
     */
    private fun extractSearchQuery(url: String): String {
        return try {
            val uri = android.net.Uri.parse(url)
            val host = uri.host?.lowercase() ?: return ""
            val param = when {
                host.contains("google.")       -> "q"
                host.contains("bing.com")      -> "q"
                host.contains("duckduckgo.")   -> "q"
                host.contains("yahoo.")        -> "p"
                host.contains("yandex.")       -> "text"
                host.contains("youtube.com")   -> "search_query"
                host.contains("brave.com")     -> "q"
                host.contains("ecosia.org")    -> "q"
                host.contains("startpage.com") -> "query"
                else -> return ""
            }
            uri.getQueryParameter(param)?.trim().orEmpty()
        } catch (_: Exception) { "" }
    }

    private fun detectSearchEngine(url: String): String {
        return try {
            val host = android.net.Uri.parse(url).host?.lowercase() ?: return ""
            when {
                host.contains("google.")       -> "Google"
                host.contains("bing.com")      -> "Bing"
                host.contains("duckduckgo.")   -> "DuckDuckGo"
                host.contains("yahoo.")        -> "Yahoo"
                host.contains("yandex.")       -> "Yandex"
                host.contains("youtube.com")   -> "YouTube"
                host.contains("brave.com")     -> "Brave"
                host.contains("ecosia.org")    -> "Ecosia"
                host.contains("startpage.com") -> "Startpage"
                else -> ""
            }
        } catch (_: Exception) { "" }
    }

    /** Throttled Firestore write of diagnostic counters. Force=true bypasses
     *  the throttle (used on meaningful state changes — connected, URL captured). */
    private fun writeDiagnosticStatus(force: Boolean = false, note: String? = null) {
        val now = System.currentTimeMillis()
        if (!force && now - lastStatusWriteTs < 10_000L) return
        lastStatusWriteTs = now

        val childId = getChildId() ?: return

        try {
            val data = hashMapOf<String, Any>(
                "eventsSeen"      to eventsSeen,
                "urlsCaptured"    to urlsCaptured,
                "lastBrowserPkg"  to lastBrowserPkg,
                "lastEventTs"     to lastEventTs,
                "lastExtractSample" to lastExtractSample,
                "updatedAt"       to Timestamp.now(),
            )
            if (note != null) data["note"] = note
            FirebaseFirestore.getInstance()
                .collection("children")
                .document(childId)
                .collection("browser_history")
                .document("status")
                .set(data)
        } catch (e: Exception) {
            Log.w(TAG, "writeDiagnosticStatus failed: ${e.message}")
        }
    }

    /** Returns the first URL-shaped or non-empty EditText text we find in the
     *  subtree, for diagnostics only. Trimmed to 80 chars. */
    private fun sampleAnyEditText(node: AccessibilityNodeInfo): String {
        val cls = node.className?.toString() ?: ""
        if (cls == "android.widget.EditText") {
            val t = node.text?.toString() ?: ""
            if (t.isNotEmpty()) return t.take(80)
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val r = sampleAnyEditText(child)
            child.recycle()
            if (r.isNotEmpty()) return r
        }
        return ""
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
            "com.android.chrome:id/toolbar_url",
            "com.android.chrome:id/omnibox_container",
            "com.chrome.beta:id/url_bar",
            "com.chrome.beta:id/location_bar",
            "com.chrome.dev:id/url_bar",
            "com.chrome.dev:id/location_bar",
            "com.chrome.canary:id/url_bar",
            "com.chrome.canary:id/location_bar",
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
                val n = nodes[0]
                val text = n.text?.toString() ?: ""
                // Newer Chrome surfaces the URL via contentDescription
                // ("Address bar, https://example.com") when the omnibox has
                // collapsed to a pill. Fall back to that when `text` is blank
                // or is placeholder text like "Search or type web address".
                val desc = n.contentDescription?.toString() ?: ""
                nodes.forEach { it.recycle() }
                if (text.isNotEmpty() && looksLikeUrl(text)) return text
                if (desc.isNotEmpty()) {
                    val extracted = extractUrlFromDescription(desc)
                    if (extracted.isNotEmpty()) return extracted
                }
            }
        }

        // Fallback: search the subtree for any EditText / TextView whose
        // contents look URL-shaped. Some browsers (e.g. DuckDuckGo on newer
        // builds) surface the URL in a plain TextView once the user leaves
        // the address bar.
        return findUrlInChildren(node)
    }

    /** Chrome/Edge/Brave often set contentDescription like
     *  "Address bar, https://example.com" or "example.com, Verified". Pull
     *  the first URL-shaped token out of that string. */
    private fun extractUrlFromDescription(desc: String): String {
        // Split on common separators and take the first looks-like-a-url token
        for (part in desc.split(',', ' ', '\n')) {
            val p = part.trim()
            if (p.isNotEmpty() && looksLikeUrl(p)) return p
        }
        return ""
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
            val desc = node.contentDescription?.toString() ?: ""
            if (desc.isNotEmpty()) {
                val extracted = extractUrlFromDescription(desc)
                if (extracted.isNotEmpty()) return extracted
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
        if (instance === this) instance = null
        Log.d(TAG, "BrowserMonitorService destroyed")
    }
}
