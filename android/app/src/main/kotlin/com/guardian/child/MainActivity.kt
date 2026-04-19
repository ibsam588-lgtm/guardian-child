package com.guardian.child

import android.app.AppOpsManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.ComponentName
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
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.guardian.child/monitor"

    // Audio recording is now handled by ListenService (a dedicated foreground
    // service) so that mic capture continues when the app is backgrounded.

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // NOTE: Do NOT start MonitorService here — it needs location permission
        // and the child must be paired first. Flutter controls it via MethodChannel.

        // Schedule a periodic WorkManager watchdog that restarts MonitorService
        // every 15 minutes if it has been killed. This is more reliable than
        // AlarmManager on Android 12+ where exact alarms require extra permission
        // and foreground service starts from background are blocked.
        val watchdogRequest = PeriodicWorkRequestBuilder<ServiceWatchdogWorker>(
            15, TimeUnit.MINUTES
        ).build()
        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "service_watchdog",
            ExistingPeriodicWorkPolicy.KEEP,
            watchdogRequest
        )

        // Request battery optimization exemption on first launch so OEM power
        // managers (Samsung, Xiaomi, etc.) don't kill MonitorService.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                try {
                    val batteryIntent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    batteryIntent.data = Uri.parse("package:$packageName")
                    startActivity(batteryIntent)
                } catch (e: Exception) {
                    Log.w("MainActivity", "Could not request battery optimization exemption: ${e.message}")
                }
            }
        }
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
                        val enabledServices = Settings.Secure.getString(
                            contentResolver,
                            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                        ) ?: ""
                        val myService = "$packageName/${BrowserMonitorService::class.java.name}"
                        result.success(enabledServices.contains(myService))
                    }

                    "openAccessibilitySettings" -> {
                        // Try to jump directly to the GuardIan accessibility service entry.
                        // The ":settings:fragment_args_key" extra is an internal Android Settings
                        // convention that works on most OEM ROMs (AOSP, Samsung, Pixel).
                        val serviceComponent = ComponentName(
                            packageName,
                            BrowserMonitorService::class.java.name
                        ).flattenToString()
                        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                            val args = Bundle()
                            args.putString(":settings:fragment_args_key", serviceComponent)
                            putExtra(":settings:show_fragment_args", args)
                            putExtra(":settings:fragment_args_key", serviceComponent)
                        }
                        try {
                            startActivity(intent)
                        } catch (e: Exception) {
                            // Fallback: open the generic accessibility settings page
                            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        }
                        result.success(null)
                    }

                    "getPendingBrowserUrls" -> {
                        try {
                            result.success(BrowserMonitorService.getPendingUrlsJson())
                        } catch (e: Exception) {
                            result.error("BROWSER_URLS_ERROR", e.message, null)
                        }
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
                        val blockedPkg = call.argument<String>("packageName") ?: ""
                        val isBlocked = call.argument<Boolean>("isBlocked") ?: false
                        try {
                            val intent = Intent(applicationContext, AppBlockedActivity::class.java).apply {
                                putExtra("packageName", blockedPkg)
                                // Tell AppBlockedActivity which kind of dialog to
                                // show: a parent-blocked app gets an unblock
                                // request (no time selector); a time-limit-reached
                                // app gets the extra-time request with spinner.
                                putExtra(
                                    AppBlockedActivity.EXTRA_REASON,
                                    if (isBlocked) AppBlockedActivity.REASON_BLOCKED
                                    else AppBlockedActivity.REASON_LIMIT_REACHED
                                )
                                // FLAG_ACTIVITY_NEW_TASK is required when starting from a
                                // non-Activity context (applicationContext). CLEAR_TOP ensures
                                // only one block screen instance exists at a time.
                                addFlags(
                                    Intent.FLAG_ACTIVITY_NEW_TASK or
                                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                                    Intent.FLAG_ACTIVITY_SINGLE_TOP
                                )
                            }
                            applicationContext.startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("BLOCK_SCREEN_ERROR", e.message, null)
                        }
                    }

                    // Ambient-listening channel methods invoked by the Dart
                    // CommandService when the parent hits "Listen Live".
                    // Dart calls `startListen` with {'childId': <id>}; we must
                    // match that name exactly or the call silently no-ops and
                    // the parent UI sits on "Connecting…" forever.
                    "startListen" -> {
                        val childId = call.argument<String>("childId").orEmpty()
                        val durationSeconds = call.argument<Int>("durationSeconds") ?: 0
                        if (childId.isBlank()) {
                            result.error(
                                "NO_CHILD_ID",
                                "startListen called without childId",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            ListenService.start(this, childId, durationSeconds)
                            result.success("foreground_service")
                        } catch (e: Exception) {
                            result.error("RECORDING_ERROR", e.message, null)
                        }
                    }

                    "stopListen" -> {
                        try {
                            ListenService.stop(this)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("RECORDING_ERROR", e.message, null)
                        }
                    }

                    // Called by Dart _writeFenceAlert when a geofence
                    // enter/exit transition fires. We post a local
                    // notification so the child sees the alert directly
                    // on their phone — not only the parent via FCM.
                    // User request: 'if childs location is out of the
                    // geofence it should trigger an alert both to the
                    // parent and child, system notification basically.'
                    "showGeofenceNotification" -> {
                        val title = call.argument<String>("title")
                            ?: "Geofence alert"
                        val body = call.argument<String>("body") ?: ""
                        val transition = call.argument<String>("transition")
                            ?: "geofence"
                        try {
                            showGeofenceLocalNotification(
                                applicationContext, title, body, transition
                            )
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("NOTIFY_ERROR", e.message, null)
                        }
                    }

                    "startRecording" -> {
                        val durationSeconds = call.argument<Int>("durationSeconds") ?: 60
                        try {
                            // Recording must run inside a foreground service so it
                            // continues when the app is backgrounded or the activity
                            // is destroyed. Read the paired childId from the Flutter
                            // SharedPreferences file (written by the Dart side on login).
                            val sp = getSharedPreferences(
                                "FlutterSharedPreferences", Context.MODE_PRIVATE)
                            val childId = sp.getString("flutter.paired_child_id", "")
                                ?: ""
                            if (childId.isBlank()) {
                                result.error(
                                    "NO_CHILD_ID",
                                    "Device not paired — cannot start recording",
                                    null
                                )
                                return@setMethodCallHandler
                            }
                            ListenService.start(this, childId, durationSeconds)
                            // Return a marker so the Dart layer knows recording is
                            // delegated to the foreground service (chunks go straight
                            // to Firestore; there is no local file path).
                            result.success("foreground_service")
                        } catch (e: Exception) {
                            result.error("RECORDING_ERROR", e.message, null)
                        }
                    }

                    "stopRecording" -> {
                        try {
                            ListenService.stop(this)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("RECORDING_ERROR", e.message, null)
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

    /** Returns the package name of the app currently in the foreground, or null.
     *  Uses a 30-second window (was 10 s) so we never miss an app that moved
     *  to foreground between enforcement ticks. */
    private fun getCurrentForegroundApp(): String? {
        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now = System.currentTimeMillis()
        val events = usm.queryEvents(now - 30_000L, now) // last 30 seconds
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
        // Match the parent-app 7-day retention policy: query 7 days of
        // history so a parent browsing the card sees the whole window
        // their UI is showing. Previous 24h window meant the card was
        // empty for most of the week even when calls existed.
        val sevenDaysAgo = System.currentTimeMillis() - 7L * 24 * 60 * 60 * 1000L

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
            arrayOf(sevenDaysAgo.toString()),
            "${CallLog.Calls.DATE} DESC"
        )

        cursor?.use {
            val maxEntries = 100
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
                    CallLog.Calls.VOICEMAIL_TYPE -> "voicemail"
                    CallLog.Calls.BLOCKED_TYPE -> "blocked"
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

    /** Returns the last 50 SMS messages from the past 24 hours.
     *
     * Historically we queried Telephony.Sms.CONTENT_URI which *should*
     * be a union view across inbox/sent/drafts — but on modern Android
     * (Samsung One UI in particular) sent messages are often stored
     * under a separate URI and the union view only returns inbox rows
     * unless the caller is the default SMS app. Firestore confirmed
     * this: communications had only type='received' rows even though
     * the child had sent messages.
     *
     * Fix: query inbox and sent URIs explicitly and merge the results.
     * Duplicates are avoided by keying on (address, date, body).
     */
    private fun getRecentSmsLog(): List<Map<String, Any?>> {
        val sevenDaysAgo = System.currentTimeMillis() - 7L * 24 * 60 * 60 * 1000L
        val all = mutableListOf<Map<String, Any?>>()
        val seen = HashSet<String>()

        // Inbox (received) and Sent as explicit URIs, plus the union
        // CONTENT_URI as a fallback in case one of the specific URIs
        // is missing on this OEM. Also include OUTBOX which is
        // 'pending send' — still useful context for the parent.
        val sources = listOf(
            Telephony.Sms.Inbox.CONTENT_URI to "received",
            Telephony.Sms.Sent.CONTENT_URI  to "sent",
            Telephony.Sms.Outbox.CONTENT_URI to "sent",
            Telephony.Sms.CONTENT_URI        to null, // null means derive from TYPE column
        )

        for ((uri, fixedType) in sources) {
            val cursor: Cursor? = try {
                contentResolver.query(
                    uri,
                    arrayOf(
                        Telephony.Sms.ADDRESS,
                        Telephony.Sms.BODY,
                        Telephony.Sms.TYPE,
                        Telephony.Sms.DATE,
                    ),
                    "${Telephony.Sms.DATE} > ?",
                    arrayOf(sevenDaysAgo.toString()),
                    "${Telephony.Sms.DATE} DESC",
                )
            } catch (e: Exception) {
                Log.w("MainActivity", "sms query failed for $uri: ${e.message}")
                null
            }

            cursor?.use {
                var count = 0
                while (it.moveToNext() && count < 100) {
                    val address = it.getString(0) ?: ""
                    val body = it.getString(1) ?: ""
                    val rawType = it.getInt(2)
                    val date = it.getLong(3)

                    val typeStr = fixedType ?: when (rawType) {
                        Telephony.Sms.MESSAGE_TYPE_INBOX -> "received"
                        Telephony.Sms.MESSAGE_TYPE_SENT  -> "sent"
                        Telephony.Sms.MESSAGE_TYPE_OUTBOX -> "sent"
                        Telephony.Sms.MESSAGE_TYPE_DRAFT -> "draft"
                        else -> "unknown"
                    }

                    // Dedup key — same message can appear in both the
                    // union URI and one of the type-specific URIs.
                    val key = "$address|$date|${body.length}"
                    if (seen.add(key)) {
                        all.add(mapOf(
                            "address" to address,
                            "contactName" to resolveContactName(address),
                            "body" to body,
                            "type" to typeStr,
                            "date" to date,
                        ))
                    }
                    count++
                }
            }
        }

        // Global cap after merge.
        all.sortByDescending { (it["date"] as? Long) ?: 0L }
        return all.take(100)
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

    companion object {
        private const val GEOFENCE_CHANNEL_ID = "guardian_geofence_channel"
        private var geofenceNotificationId = 2000

        /**
         * Post a local notification when the child crosses a geofence
         * boundary. Fires regardless of FCM / parent-device state so
         * the child sees immediate feedback on their own phone.
         */
        fun showGeofenceLocalNotification(
            context: Context,
            title: String,
            body: String,
            transition: String,
        ) {
            val nm = context.getSystemService(NotificationManager::class.java)
                ?: return

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // High-importance channel — the child should hear / see
                // this immediately even if their phone is on vibrate.
                val existing = nm.getNotificationChannel(GEOFENCE_CHANNEL_ID)
                if (existing == null) {
                    val channel = NotificationChannel(
                        GEOFENCE_CHANNEL_ID,
                        "Geofence alerts",
                        NotificationManager.IMPORTANCE_HIGH,
                    ).apply {
                        description = "Fired when you enter or leave a zone your parent set."
                        enableVibration(true)
                        enableLights(true)
                    }
                    nm.createNotificationChannel(channel)
                }
            }

            // Tapping the notification opens the main app.
            val launchIntent = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
            val contentPi = if (launchIntent != null) {
                PendingIntent.getActivity(
                    context,
                    0,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            } else null

            val iconRes = context.applicationInfo.icon.takeIf { it != 0 }
                ?: android.R.drawable.ic_dialog_map

            val builder = NotificationCompat.Builder(context, GEOFENCE_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setSmallIcon(iconRes)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS)

            if (contentPi != null) builder.setContentIntent(contentPi)

            try {
                nm.notify(geofenceNotificationId++, builder.build())
            } catch (e: SecurityException) {
                // POST_NOTIFICATIONS not granted on Android 13+ — silent
                // no-op. The child has to grant that permission during
                // onboarding for this to fire.
                Log.w("MainActivity", "geofence notify denied: ${e.message}")
            }
        }
    }

}
