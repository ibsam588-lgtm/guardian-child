package com.guardian.child

import android.accessibilityservice.AccessibilityService
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.google.firebase.FirebaseApp
import com.google.firebase.Timestamp
import com.google.firebase.firestore.FieldValue
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
            "com.sec.android.app.sbrowser",
            // Google app hosts the home-screen search widget and the
            // in-app search that Chrome sometimes delegates to. Treating
            // it as a browser lets us capture ?q= searches done from
            // the widget before Chrome ever opens.
            "com.google.android.googlequicksearchbox",
            // Samsung's version of the Google Search shortcut.
            "com.samsung.android.app.galaxyfinder",
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

    // ── MonitorService watchdog ───────────────────────────────────────────────
    // Accessibility services are exempt from OEM battery-optimisation kills,
    // so we use this service as a reliable heartbeat to restart MonitorService
    // whenever the OEM has killed it.
    private val handler = Handler(Looper.getMainLooper())
    private val serviceCheckRunnable = object : Runnable {
        override fun run() {
            ensureMonitorServiceRunning()
            handler.postDelayed(this, 30_000L) // check every 30 seconds
        }
    }

    private fun ensureMonitorServiceRunning() {
        val manager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        @Suppress("DEPRECATION")
        val running = manager.getRunningServices(Int.MAX_VALUE)
            .any { it.service.className == MonitorService::class.java.name }
        if (!running) {
            Log.d(TAG, "MonitorService not running — restarting")
            val intent = Intent(this, MonitorService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not restart MonitorService: ${e.message}")
            }
        }
    }

    // ── Diagnostics ────────────────────────────────────────────────────────
    // We write a status doc to children/{childId}/browser_history/status so
    // the parent can tell the difference between:
    //   (a) service not running at all (no doc)
    //   (b) service running but no browser events arriving (eventsSeen == 0)
    //   (c) events arriving but URL extraction failing (eventsSeen > 0, urlsCaptured == 0)
    //   (d) everything working (urlsCaptured > 0)
    private var eventsSeen: Long = 0
    private var urlsCaptured: Long = 0
    private var writesAttempted: Long = 0
    private var writesFailed: Long = 0
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
        // Start the MonitorService watchdog loop. Accessibility services are
        // protected from OEM battery-optimisation kills, so this is the most
        // reliable place to ensure MonitorService keeps running.
        ensureMonitorServiceRunning()
        handler.postDelayed(serviceCheckRunnable, 30_000L)
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
            event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            event.eventType != AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED) return

        eventsSeen += 1
        lastBrowserPkg = packageName
        lastEventTs = System.currentTimeMillis()

        try {
            val rootNode = rootInActiveWindow
            if (rootNode == null) {
                writeDiagnosticStatus(note = "rootInActiveWindow=null")
                return
            }

            // Google Search widget / Samsung Finder don't have a URL bar
            // — the user just types a query and the app sends it to the
            // system browser. Capture the typed text directly as a
            // search query so the parent sees what was searched even
            // though no real URL ever renders in this app.
            //
            // Gated to TYPE_VIEW_TEXT_CHANGED (user typing) — not the
            // generic WINDOW_CONTENT_CHANGED ticks that fire constantly
            // while the widget is open, each of which was previously
            // triggering a new write with whatever text happened to be
            // in any EditText at that instant. That was one cause of
            // the 'browser activity is broke now' regression after
            // v1.0.16 — stale or empty scans from the widget were
            // queuing synthetic entries.
            if (packageName == "com.google.android.googlequicksearchbox" ||
                packageName == "com.samsung.android.app.galaxyfinder") {
                val isTextChange =
                    event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED
                if (!isTextChange) {
                    rootNode.recycle()
                    writeDiagnosticStatus()
                    return
                }
                val query = extractSearchBoxText(rootNode)
                rootNode.recycle()
                // Require a query that looks like a real search (>=3
                // chars, has a letter) so keystroke-by-keystroke
                // scraps ('a', 'ap', 'app') don't each get written.
                val lastPref = prefs?.getString("last_widget_query", "") ?: ""
                val looksLikeSearch =
                    query.length >= 3 && query.any { it.isLetter() }
                if (looksLikeSearch && query != lastPref && query != lastUrl) {
                    lastUrl = query
                    urlsCaptured += 1
                    val synthetic =
                        "https://www.google.com/search?q=" +
                            java.net.URLEncoder.encode(query, "UTF-8")
                    prefs?.edit()
                        ?.putString("last_widget_query", query)
                        ?.putString("last_url", synthetic)
                        ?.putLong("last_url_time", System.currentTimeMillis())
                        ?.putString("last_browser", packageName)
                        ?.apply()
                    val entry = mapOf<String, Any>(
                        "url" to synthetic,
                        "packageName" to packageName,
                        "timestamp" to System.currentTimeMillis(),
                    )
                    synchronized(pendingUrls) {
                        pendingUrls.addLast(entry)
                        while (pendingUrls.size > 200) pendingUrls.removeFirst()
                    }
                    Log.d(TAG, "Google-widget search: $query")
                    writeUrlToFirestore(synthetic, packageName, query, "")
                }
                writeDiagnosticStatus()
                return
            }

            val url = extractUrl(rootNode)
            if (url.isEmpty()) {
                // Sample first EditText text we can find so the parent can tell
                // whether the URL bar is just showing placeholder text vs. the
                // extraction not finding the node at all.
                lastExtractSample = sampleAnyEditText(rootNode)
            }
            // Fallback search-query extraction: Chrome's omnibox often
            // collapses google.com/search?q=foo down to just the domain
            // pill, so extractSearchQuery(url) returns empty. Walk the
            // accessibility tree for a title-shaped node matching known
            // patterns ("foo - Google Search", "foo - YouTube", "foo at
            // DuckDuckGo") as a secondary source. Done while rootNode is
            // still alive.
            val titleQuery = if (url.isNotEmpty() && extractSearchQuery(url).isEmpty()) {
                scanForSearchTitle(rootNode, url)
            } else ""
            // Additional fallback: find the first plausible page-title
            // text node so we ALWAYS have something parent-facing even
            // when search-term extraction fails. For non-search pages
            // this is useful context too ('Read a book on Wikipedia'
            // is more informative than 'en.wikipedia.org/wiki/...').
            val pageTitle = findPageTitle(rootNode, url)
            if (pageTitle.isNotEmpty()) {
                prefs?.edit()?.putString("last_page_title", pageTitle.take(120))?.apply()
            }
            rootNode.recycle()

            if (url.isEmpty() || url == lastUrl) {
                // Previously we synthesized a 'google.com/search?q=...'
                // or 'about:blank' entry when URL extraction failed but
                // pageTitle/titleQuery captured something. That caused
                // every transient empty-URL event (VERY common between
                // navigations on every browser, not just Firefox) to
                // queue a synthetic entry — flooding browser_history
                // with duplicate-per-keystroke garbage and breaking
                // the whole Browser Activity tab. Reverted. The
                // Firefox-diagnostic-but-not-rendered case will need
                // a different fix (likely: only synthesize when the
                // page TITLE has been stable across N consecutive
                // reads, not on every empty-URL tick).
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
            writeUrlToFirestore(url, packageName, titleQuery, pageTitle)

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
    private fun writeUrlToFirestore(
        url: String,
        packageName: String,
        titleFallback: String = "",
        pageTitle: String = "",
    ) {
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
        val urlQuery = extractSearchQuery(url)
        val searchQuery = when {
            urlQuery.isNotEmpty() -> urlQuery
            titleFallback.isNotEmpty() -> titleFallback
            else -> ""
        }
        val entry = hashMapOf<String, Any>(
            "url"       to url,
            "browser"   to packageName,
            "visitedAt" to FieldValue.serverTimestamp(),
        )
        if (searchQuery.isNotEmpty()) {
            entry["searchQuery"] = searchQuery
            entry["searchEngine"] = detectSearchEngine(url)
        }
        if (pageTitle.isNotEmpty()) {
            entry["pageTitle"] = pageTitle
        }

        val col = FirebaseFirestore.getInstance()
            .collection("children")
            .document(childId)
            .collection("browser_history")

        writesAttempted += 1
        col.add(entry)
            .addOnFailureListener { e ->
                writesFailed += 1
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

    /**
     * Secondary search-query extractor for the case Chrome/other browsers
     * strip ?q=... from the visible omnibox. The result-page tab title
     * usually still contains the query — e.g. "cool minecraft mods - Google
     * Search" or "learn kotlin - YouTube". Walk the subtree looking for a
     * TextView whose text matches one of those patterns.
     *
     * Regex notes:
     * - Accept hyphen-minus (-), en-dash (–), and em-dash (—) as the
     *   separator since different Chrome versions / locales vary.
     * - Use \s+ for whitespace, not literal spaces, so non-breaking or
     *   wide spaces don't break the match.
     * - The Google suffix is localised ("Google Search" / "Google
     *   Recherche" / "Google 検索" / etc). We match a looser
     *   '.*?Google.*?' tail so any language works.
     *
     * We skip the URL bar itself and only consider nodes with non-trivial
     * text content so we don't grab toolbar button labels or the like.
     */
    private fun scanForSearchTitle(
        root: AccessibilityNodeInfo,
        url: String,
    ): String {
        val engine = detectSearchEngine(url).ifEmpty { return "" }
        // Separator class: hyphen-minus, en-dash, em-dash, figure dash, minus sign
        val sep = """[\s]+[-\u2010\u2011\u2012\u2013\u2014\u2212][\s]+"""
        val pattern = when (engine) {
            "Google"     -> Regex("""^(.{1,200}?)$sep.*?Google.*$""", RegexOption.IGNORE_CASE)
            "YouTube"    -> Regex("""^(.{1,200}?)$sep.*?YouTube.*$""", RegexOption.IGNORE_CASE)
            "Bing"       -> Regex("""^(.{1,200}?)$sep.*?Bing.*$""", RegexOption.IGNORE_CASE)
            "DuckDuckGo" -> Regex("""^(.{1,200}?)(?:$sep|\s+at\s+).*?DuckDuckGo.*$""", RegexOption.IGNORE_CASE)
            "Yahoo"      -> Regex("""^(.{1,200}?)$sep.*?Yahoo.*$""", RegexOption.IGNORE_CASE)
            "Brave"      -> Regex("""^(.{1,200}?)$sep.*?Brave.*$""", RegexOption.IGNORE_CASE)
            "Ecosia"     -> Regex("""^(.{1,200}?)$sep.*?Ecosia.*$""", RegexOption.IGNORE_CASE)
            "Startpage"  -> Regex("""^(.{1,200}?)$sep.*?Startpage.*$""", RegexOption.IGNORE_CASE)
            "Yandex"     -> Regex("""^(.{1,200}?)$sep.*?Yandex.*$""", RegexOption.IGNORE_CASE)
            else         -> return ""
        }
        return try {
            val hit = findMatchingText(root, pattern, depth = 0, maxDepth = 12)
            // Write a diagnostic breadcrumb so we can tell, from the
            // parent's logs, whether extraction is failing because the
            // tree scan ran and found nothing vs. was never reached.
            if (hit.isEmpty()) {
                prefs?.edit()?.putString("last_title_scan",
                    "miss:$engine")?.apply()
            } else {
                prefs?.edit()?.putString("last_title_scan",
                    "hit:$engine:${hit.take(40)}")?.apply()
            }
            hit
        } catch (_: Exception) { "" }
    }

    /**
     * DFS-walk the node tree looking for any `text` that matches [pattern].
     * Returns the first captured group, or empty on no match. Bounded
     * depth/width so we don't burn CPU on deeply nested result lists.
     */
    private fun findMatchingText(
        node: AccessibilityNodeInfo?,
        pattern: Regex,
        depth: Int,
        maxDepth: Int,
    ): String {
        if (node == null || depth > maxDepth) return ""
        val text = node.text?.toString()?.trim().orEmpty()
        if (text.isNotEmpty()) {
            val m = pattern.matchEntire(text)
            if (m != null) return m.groupValues[1].trim()
        }
        val contentDesc = node.contentDescription?.toString()?.trim().orEmpty()
        if (contentDesc.isNotEmpty()) {
            val m = pattern.matchEntire(contentDesc)
            if (m != null) return m.groupValues[1].trim()
        }
        val count = node.childCount.coerceAtMost(40) // width cap
        for (i in 0 until count) {
            val child = node.getChild(i) ?: continue
            val r = findMatchingText(child, pattern, depth + 1, maxDepth)
            child.recycle()
            if (r.isNotEmpty()) return r
        }
        return ""
    }

    /**
     * Best-effort page-title extractor. Returns the first text node that
     * looks like a plausible page/tab title — long enough to be
     * informative, short enough to fit on a row, and not the URL itself
     * or a known button/control label. Used as a fallback when the
     * search-term extractors both fail, so the parent UI has something
     * better than a bare URL to show.
     *
     * Heuristics:
     *  - 10 to 200 chars after trim
     *  - doesn't start with http:// or https://
     *  - doesn't contain the URL's host (to avoid grabbing the omnibox text)
     *  - isn't a single word that looks like a toolbar label ("Menu",
     *    "More", "Tab", "Back", "Forward", etc.)
     *  - preferred: AccessibilityNodeInfo.paneTitle when set by Chrome
     *    on the web content frame (Android O+)
     */
    private fun findPageTitle(
        root: AccessibilityNodeInfo,
        url: String,
    ): String {
        // Extract host so we can reject nodes whose text matches the URL
        // bar (which would produce pageTitle = 'google.com/search' —
        // exactly the noise we're trying to get rid of).
        val host = try {
            android.net.Uri.parse(url).host?.lowercase().orEmpty()
        } catch (_: Exception) { "" }

        // Chrome exposes the tab's page title via the web-content frame's
        // paneTitle from Android O onward. Check that first — it's the
        // cleanest source and bypasses the DFS entirely.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val paneHit = findPaneTitle(root, host, depth = 0, maxDepth = 12)
            if (paneHit.isNotEmpty()) return paneHit
        }

        return try {
            scanForPlausibleTitle(root, host, url, depth = 0, maxDepth = 12)
        } catch (_: Exception) { "" }
    }

    private fun findPaneTitle(
        node: AccessibilityNodeInfo?,
        host: String,
        depth: Int,
        maxDepth: Int,
    ): String {
        if (node == null || depth > maxDepth) return ""
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val pane = node.paneTitle?.toString()?.trim().orEmpty()
            if (pane.length in 10..200 &&
                !pane.startsWith("http://") &&
                !pane.startsWith("https://") &&
                (host.isEmpty() || !pane.lowercase().contains(host))) {
                return pane
            }
        }
        val count = node.childCount.coerceAtMost(40)
        for (i in 0 until count) {
            val child = node.getChild(i) ?: continue
            val r = findPaneTitle(child, host, depth + 1, maxDepth)
            child.recycle()
            if (r.isNotEmpty()) return r
        }
        return ""
    }

    private fun scanForPlausibleTitle(
        node: AccessibilityNodeInfo?,
        host: String,
        url: String,
        depth: Int,
        maxDepth: Int,
    ): String {
        if (node == null || depth > maxDepth) return ""

        // Skip the URL-bar subtree entirely — we know its text is the
        // URL itself, so descending it just produces noise.
        val viewId = node.viewIdResourceName?.lowercase().orEmpty()
        val isUrlBar = viewId.contains("url_bar") ||
            viewId.contains("omnibox") ||
            viewId.contains("location_bar") ||
            viewId.contains("mozac_browser_toolbar")
        if (!isUrlBar) {
            val text = node.text?.toString()?.trim().orEmpty()
            if (isPlausibleTitle(text, host, url)) return text
        }

        val count = node.childCount.coerceAtMost(40)
        for (i in 0 until count) {
            val child = node.getChild(i) ?: continue
            val r = scanForPlausibleTitle(child, host, url, depth + 1, maxDepth)
            child.recycle()
            if (r.isNotEmpty()) return r
        }
        return ""
    }

    private fun isPlausibleTitle(
        text: String,
        host: String,
        url: String,
    ): Boolean {
        if (text.length < 10 || text.length > 200) return false
        if (text.startsWith("http://") || text.startsWith("https://")) return false
        // Reject the URL itself and any text that contains the host —
        // that's almost certainly a URL-bar rendering, not a title.
        val lc = text.lowercase()
        if (host.isNotEmpty() && lc.contains(host)) return false
        if (lc == url.lowercase()) return false
        // Reject text that looks like a breadcrumb of path segments.
        if (text.count { it == '/' } >= 3 && !text.contains(' ')) return false
        // Reject common toolbar / button labels that sneak in above the
        // length threshold — unlikely but cheap to guard.
        val junkPhrases = listOf(
            "refresh page", "new incognito tab", "close tab",
            "back", "forward", "stop loading", "more options",
        )
        if (junkPhrases.any { lc == it }) return false
        return true
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
                "writesAttempted" to writesAttempted,
                "writesFailed"    to writesFailed,
                "lastBrowserPkg"  to lastBrowserPkg,
                "lastEventTs"     to lastEventTs,
                "lastExtractSample" to lastExtractSample,
                "updatedAt"       to Timestamp.now(),
            )
            // Surface the most recent title-scan outcome and the most
            // recent pageTitle captured, so the parent-side
            // diagnostics can show what the extractor actually saw.
            // Without this we have no way to tell from the field
            // whether the extractor ran at all, ran-and-missed, or
            // captured something useful.
            val titleScan = prefs?.getString("last_title_scan", "") ?: ""
            if (titleScan.isNotEmpty()) data["lastTitleScan"] = titleScan
            val pageTitle = prefs?.getString("last_page_title", "") ?: ""
            if (pageTitle.isNotEmpty()) data["lastPageTitle"] = pageTitle
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

    /**
     * For the Google Search widget / Samsung Finder we don't have a URL
     * bar — the active query lives in a plain EditText. Scan the tree
     * for the first EditText whose text is a non-URL search-y string
     * (not a URL, not empty, not a hint/placeholder) and return its
     * trimmed contents as the query.
     */
    private fun extractSearchBoxText(root: AccessibilityNodeInfo): String {
        return findSearchBoxText(root, depth = 0, maxDepth = 12)
    }

    private fun findSearchBoxText(
        node: AccessibilityNodeInfo?,
        depth: Int,
        maxDepth: Int,
    ): String {
        if (node == null || depth > maxDepth) return ""
        val cls = node.className?.toString() ?: ""
        if (cls == "android.widget.EditText") {
            val text = node.text?.toString()?.trim().orEmpty()
            // Reject: empty, URL-shaped (we're in the search widget,
            // not Chrome), or obvious placeholders. Length ceiling
            // guards against accidentally grabbing the contents of a
            // form field that happens to be an EditText.
            if (text.isNotEmpty() &&
                text.length <= 300 &&
                !text.startsWith("http://") &&
                !text.startsWith("https://") &&
                text.lowercase() != "search" &&
                text.lowercase() != "search google or type a url"
            ) {
                return text
            }
        }
        val count = node.childCount.coerceAtMost(40)
        for (i in 0 until count) {
            val child = node.getChild(i) ?: continue
            val r = findSearchBoxText(child, depth + 1, maxDepth)
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
            "org.mozilla.firefox:id/mozac_browser_toolbar_edit_url_view",
            "org.mozilla.firefox:id/awesome_bar_edit_text",
            "org.mozilla.firefox:id/toolbar_wrapper",
            "org.mozilla.firefox_beta:id/mozac_browser_toolbar_url_view",
            "org.mozilla.firefox_beta:id/mozac_browser_toolbar_edit_url_view",
            // Opera
            "com.opera.browser:id/url_field",
            "com.opera.mini.native:id/url_field",
            // Edge — same codebase as Chromium
            "com.microsoft.emmx:id/url_bar",
            "com.microsoft.emmx:id/location_bar",
            "com.microsoft.emmx:id/omnibox_text",
            "com.microsoft.emmx:id/search_box_text",
            // Brave
            "com.brave.browser:id/url_bar",
            "com.brave.browser:id/location_bar",
            // DuckDuckGo
            "com.duckduckgo.mobile.android:id/omnibarTextInput",
            // Samsung Internet
            "com.sec.android.app.sbrowser:id/location_bar_edit_text",
            "com.sec.android.app.sbrowser:id/url_bar",
            // Google Search app / home-screen widget — the search box
            // where the user types their query BEFORE the results page
            // loads in Chrome. Capturing here gets the raw query even
            // if Chrome's omnibox later collapses the URL.
            "com.google.android.googlequicksearchbox:id/googleapp_srp_search_plate_text_view",
            "com.google.android.googlequicksearchbox:id/search_edit_frame",
            "com.google.android.googlequicksearchbox:id/search_src_text",
            "com.google.android.googlequicksearchbox:id/search_plate",
            "com.google.android.googlequicksearchbox:id/googleapp_search_plate"
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
        // Reject transient placeholder strings that Chrome and friends
        // display in the URL-bar TextView during navigation. These
        // contain dots and no spaces so the weak heuristic below would
        // otherwise accept them — we've seen hundreds of
        // 'url: "Loading..."' docs in Firestore from this bug.
        val lc = text.lowercase().trimEnd('.', '…', ' ')
        if (lc == "loading" ||
            lc == "connecting" ||
            lc == "reconnecting" ||
            lc == "waiting for" ||
            lc == "finishing" ||
            lc == "redirecting") {
            return false
        }
        // Either has a scheme, or a dot with no whitespace (e.g. "example.com/foo")
        if (text.startsWith("http://") || text.startsWith("https://")) return true
        // Require a letter in the domain-shaped token so literal
        // punctuation like '...' or '-.-' is also rejected.
        if (!text.any { it.isLetter() }) return false
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
        handler.removeCallbacks(serviceCheckRunnable)
    }

    override fun onDestroy() {
        super.onDestroy()
        handler.removeCallbacks(serviceCheckRunnable)
        if (instance === this) instance = null
        Log.d(TAG, "BrowserMonitorService destroyed")
    }
}
