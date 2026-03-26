package com.guardian.child

import android.app.AppOpsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.guardian.child/monitor"
    private var sirenPlayer: MediaPlayer? = null

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
                    "openUsageAccessSettings" -> {
                        startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                        result.success(null)
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
                    "playSiren" -> {
                    playSiren()
                    result.success(null)
                }
                "stopSiren" -> {
                    stopSiren()
                    result.success(null)
                }
                else -> result.notImplemented()
                }
            }
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

    private fun playSiren() {
        stopSiren()
        try {
            val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            sirenPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(this@MainActivity, alarmUri)
                isLooping = true
                prepare()
                start()
            }
            // Auto-stop after 30 seconds
            android.os.Handler(mainLooper).postDelayed({ stopSiren() }, 30_000)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun stopSiren() {
        sirenPlayer?.let {
            if (it.isPlaying) it.stop()
            it.release()
        }
        sirenPlayer = null
    }

    /** Returns a map of packageName → minutesUsed today (since midnight). */
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
}
