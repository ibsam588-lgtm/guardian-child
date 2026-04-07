package com.guardian.child

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.Settings
import android.provider.Telephony
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.guardian.child/monitor"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // NOTE: Do NOT start MonitorService here — it needs location permission
        // and the child must be paired first. Flutter controls it via MethodChannel.
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "startForegroundService" -> {
                        MonitorService.start(this)
                        result.success(null)
                    }

                    "stopForegroundService" -> {
                        MonitorService.stop(this)
                        result.success(null)
                    }

                    "hasUsageStatsPermission" -> {
                        result.success(hasUsageStatsPermission())
                    }

                    "openUsageAccessSettings", "openUsageStatsSettings" -> {
                        startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                        result.success(null)
                    }

                    "openBatteryOptimization" -> {
                        try {
                            val intent = Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                        } catch (e: Exception) {
                            // Fallback to general battery settings
                            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                        }
                        result.success(null)
                    }

                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }

                    "getAppUsage" -> {
                        if (!hasUsageStatsPermission()) {
                            result.error("PERMISSION_DENIED", "Usage stats permission not granted", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(getTodayAppUsageMinutes())
                        } catch (e: Exception) {
                            result.error("USAGE_STATS_ERROR", e.message, null)
                        }
                    }

                    "getInstalledApps" -> {
                        try {
                            result.success(getInstalledApps())
                        } catch (e: Exception) {
                            result.error("INSTALLED_APPS_ERROR", e.message, null)
                        }
                    }

                    "hasAccessibilityPermission" -> {
                        // Placeholder — accessibility service is currently disabled
                        result.success(false)
                    }

                    "openAccessibilitySettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(null)
                    }

                    "getCallLog" -> {
                        if (!hasPermission(android.Manifest.permission.READ_CALL_LOG)) {
                            result.error("PERMISSION_DENIED", "Call log permission not granted", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(getRecentCallLog())
                        } catch (e: Exception) {
                            result.error("CALL_LOG_ERROR", e.message, null)
                        }
                    }

                    "getSmsLog" -> {
                        if (!hasPermission(android.Manifest.permission.READ_SMS)) {
                            result.error("PERMISSION_DENIED", "SMS permission not granted", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(getRecentSmsLog())
                        } catch (e: Exception) {
                            result.error("SMS_LOG_ERROR", e.message, null)
                        }
                    }

                    "hasCommsPermission" -> {
                        result.success(
                            hasPermission(android.Manifest.permission.READ_CALL_LOG) &&
                            hasPermission(android.Manifest.permission.READ_SMS)
                        )
                    }

                    "playSiren" -> {
                        try {
                            SirenService.start(this)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("SIREN_ERROR", e.message, null)
                        }
                    }

                    "stopSiren" -> {
                        try {
                            SirenService.stop(this)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("SIREN_ERROR", e.message, null)
                        }
                    }

                    "getCurrentForegroundApp" -> {
                        if (!hasUsageStatsPermission()) {
                            result.error("PERMISSION_DENIED", "Usage stats permission not granted", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(getCurrentForegroundApp())
                        } catch (e: Exception) {
                            result.error("FOREGROUND_APP_ERROR", e.message, null)
                        }
                    }

                    "launchBlockScreen" -> {
                        val packageName = call.argument<String>("packageName") ?: ""
                        try {
                            val intent = Intent(this, AppBlockedActivity::class.java).apply {
                                putExtra("packageName", packageName)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("BLOCK_SCREEN_ERROR", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // ── Permission helpers ────────────────────────────────────────────────────

    private fun hasPermission(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(this, permission) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun hasUsageStatsPermission(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    // ── Installed apps ────────────────────────────────────────────────────────

    /** Returns a list of installed apps with package name, app name, and system flag. */
    private fun getInstalledApps(): List<Map<String, Any>> {
        val pm = packageManager
        val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
        return apps.map { appInfo ->
            val appName = pm.getApplicationLabel(appInfo).toString()
            val isSystem = (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            mapOf(
                "packageName" to appInfo.packageName,
                "appName" to appName,
                "isSystem" to isSystem
            )
        }.sortedBy { it["appName"] as String }
    }

    // ── App usage ─────────────────────────────────────────────────────────────

    /** Returns a map of packageName -> minutesUsed today (since midnight). */
    private fun getTodayAppUsageMinutes(): Map<String, Int> {
        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val stats = usm.queryUsageStats(
            UsageStatsManager.INTERVAL_DAILY,
            cal.timeInMillis,
            System.currentTimeMillis()
        ) ?: return emptyMap()

        return stats
            .filter { it.totalTimeInForeground > 0 }
            .associate { it.packageName to (it.totalTimeInForeground / 60_000L).toInt() }
    }

    /** Returns the package name of the app currently in the foreground, or null. */
    private fun getCurrentForegroundApp(): String? {
        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now = System.currentTimeMillis()
        val events = usm.queryEvents(now - 10_000L, now) // last 10 seconds
        val event = UsageEvents.Event()
        var lastForegroundPkg: String? = null
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            if (event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND) {
                lastForegroundPkg = event.packageName
            }
        }
        return lastForegroundPkg
    }

    // ── Call log ──────────────────────────────────────────────────────────────

    /** Returns the last 50 call log entries from the past 24 hours. */
    private fun getRecentCallLog(): List<Map<String, Any?>> {
        val results = mutableListOf<Map<String, Any?>>()
        val oneDayAgo = System.currentTimeMillis() - 24 * 60 * 60 * 1000L

        val cursor: Cursor? = contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(
                CallLog.Calls.NUMBER,
                CallLog.Calls.CACHED_NAME,
                CallLog.Calls.TYPE,
                CallLog.Calls.DATE,
                CallLog.Calls.DURATION
            ),
            "${CallLog.Calls.DATE} > ?",
            arrayOf(oneDayAgo.toString()),
            "${CallLog.Calls.DATE} DESC"
        )

        cursor?.use {
            val maxEntries = 50
            var count = 0
            while (it.moveToNext() && count < maxEntries) {
                val number = it.getString(0) ?: ""
                val name = it.getString(1)
                val type = it.getInt(2)
                val date = it.getLong(3)
                val duration = it.getInt(4)

                val typeStr = when (type) {
                    CallLog.Calls.INCOMING_TYPE -> "incoming"
                    CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                    CallLog.Calls.MISSED_TYPE -> "missed"
                    CallLog.Calls.REJECTED_TYPE -> "rejected"
                    else -> "unknown"
                }

                results.add(mapOf(
                    "number" to number,
                    "contactName" to (name ?: resolveContactName(number)),
                    "type" to typeStr,
                    "date" to date,
                    "durationSeconds" to duration
                ))
                count++
            }
        }

        return results
    }

    // ── SMS log ──────────────────────────────────────────────────────────────

    /** Returns the last 50 SMS messages from the past 24 hours. */
    private fun getRecentSmsLog(): List<Map<String, Any?>> {
        val results = mutableListOf<Map<String, Any?>>()
        val oneDayAgo = System.currentTimeMillis() - 24 * 60 * 60 * 1000L

        val cursor: Cursor? = contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.TYPE,
                Telephony.Sms.DATE
            ),
            "${Telephony.Sms.DATE} > ?",
            arrayOf(oneDayAgo.toString()),
            "${Telephony.Sms.DATE} DESC"
        )

        cursor?.use {
            val maxEntries = 50
            var count = 0
            while (it.moveToNext() && count < maxEntries) {
                val address = it.getString(0) ?: ""
                val body = it.getString(1) ?: ""
                val type = it.getInt(2)
                val date = it.getLong(3)

                val typeStr = when (type) {
                    Telephony.Sms.MESSAGE_TYPE_INBOX -> "received"
                    Telephony.Sms.MESSAGE_TYPE_SENT -> "sent"
                    Telephony.Sms.MESSAGE_TYPE_DRAFT -> "draft"
                    else -> "unknown"
                }

                results.add(mapOf(
                    "address" to address,
                    "contactName" to resolveContactName(address),
                    "body" to body,
                    "type" to typeStr,
                    "date" to date
                ))
                count++
            }
        }

        return results
    }

    // ── Contact name resolver ────────────────────────────────────────────────

    /** Tries to resolve a phone number to a contact name. Returns null if not found. */
    private fun resolveContactName(phoneNumber: String): String? {
        if (phoneNumber.isBlank()) return null
        if (!hasPermission(android.Manifest.permission.READ_CONTACTS)) return null

        try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                Uri.encode(phoneNumber)
            )
            val cursor = contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null, null, null
            )
            cursor?.use {
                if (it.moveToFirst()) {
                    return it.getString(0)
                }
            }
        } catch (_: Exception) {
            // Security exception or other error — just return null
        }
        return null
    }

}
