package com.guardian.child

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.content.SharedPreferences
import android.util.Log

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
                        var lastUrl: String = ""
                    private set
                var urlHistory: MutableList<Map<String, Any>> = mutableListOf()
                            private set
      }

          private var prefs: SharedPreferences? = null

      override fun onServiceConnected() {
                super.onServiceConnected()
                        prefs = getSharedPreferences("browser_monitor", MODE_PRIVATE)
                                Log.d(TAG, "BrowserMonitorService connected")
      }

          override fun onAccessibilityEvent(event: AccessibilityEvent?) {
                    if (event == null) return
                    val packageName = event.packageName?.toString() ?: return

                    if (packageName !in BROWSER_PACKAGES) return

                    if (event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED ||
                                    event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
                                  try {
                                                    val rootNode = rootInActiveWindow ?: return
                                                    val url = extractUrl(rootNode)
                                                                    if (url.isNotEmpty() && url != lastUrl) {
                                                                                          lastUrl = url
                                                                                          val entry = mapOf<String, Any>(
                                                                                                                    "url" to url,
                                                                                                                    "packageName" to packageName,
                                                                                                                    "timestamp" to System.currentTimeMillis()
                                                                                                                                        )
                                                                                                              urlHistory.add(entry)
                                                                                                              
                                                                                                                                  // Keep only last 100 entries in memory
                                                                                                                                                      if (urlHistory.size > 100) {
                                                                                                                                                                                urlHistory = urlHistory.takeLast(100).toMutableList()
                                                                                                                                                      }
                                                                                                                                                      
                                                                                                                                                                          // Save to SharedPreferences for Flutter to read
                                                                                                                                                                                              prefs?.edit()?.putString("last_url", url)?.apply()
                                                                                                                                                                                                                  prefs?.edit()?.putLong("last_url_time", System.currentTimeMillis())?.apply()
                                                                                                                                                                                                                                      prefs?.edit()?.putString("last_browser", packageName)?.apply()
                                                                                                                                                                                                                                      
                                                                                                                                                                                                                                                          Log.d(TAG, "Browser URL: $url from $packageName")
                                                                                                                                                                                                                                                                          }
                                                                                    rootNode.recycle()
                                  } catch (e: Exception) {
                                                    Log.e(TAG, "Error reading browser URL", e)
                                  }
                    }
          }

              private fun extractUrl(node: AccessibilityNodeInfo): String {
                        // Try to find URL bar by common IDs
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
                                                          if (nodes != null && nodes.isNotEmpty()) {
                                                                            val text = nodes[0].text?.toString() ?: ""
                                                                            nodes.forEach { it.recycle() }
                                                                                            if (text.isNotEmpty()) return text
                                                          }
                                }

                                        // Fallback: search for EditText nodes with URL-like content
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
