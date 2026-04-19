package com.guardian.child

import android.Manifest
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat

class MonitorService : Service() {

    companion object {
        const val CHANNEL_ID = "guardian_monitor_channel"
        const val NOTIFICATION_ID = 1001
        private const val TAG = "MonitorService"

        fun start(context: Context) {
            try {
                val intent = Intent(context, MonitorService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not start foreground service: ${e.message}")
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, MonitorService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "Could not stop service: ${e.message}")
            }
        }

        fun hasLocationPermission(context: Context): Boolean {
            return ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_COARSE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()

        // On Android 14+, startForeground with foregroundServiceType=location
        // throws SecurityException if location permission is not granted.
        // Check before calling to prevent crash.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            if (!hasLocationPermission(this)) {
                Log.w(TAG, "Location permission not granted — stopping service gracefully")
                stopSelf()
                return
            }
        }

        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (e: SecurityException) {
            // Android 14+: location permission denied after service started
            Log.w(TAG, "startForeground SecurityException (no location permission): ${e.message}")
            stopSelf()
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed: ${e.message}")
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Called when the user swipes the app away from the recents screen.
     * Schedule a 1-second delayed restart via AlarmManager so monitoring
     * continues even after task removal.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val restartIntent = Intent(applicationContext, MonitorService::class.java)
        restartIntent.setPackage(packageName)
        val restartPendingIntent = PendingIntent.getService(
            applicationContext,
            1,
            restartIntent,
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
        )
        val alarmManager = getSystemService(ALARM_SERVICE) as AlarmManager
        alarmManager.set(
            AlarmManager.ELAPSED_REALTIME,
            SystemClock.elapsedRealtime() + 1000,
            restartPendingIntent
        )
        Log.d(TAG, "onTaskRemoved — scheduled service restart in 1 s")
        super.onTaskRemoved(rootIntent)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "GuardIan Monitor",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps GuardIan running in the background"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val openAppIntent = packageManager
            .getLaunchIntentForPackage(packageName)
            ?.apply { flags = Intent.FLAG_ACTIVITY_SINGLE_TOP }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("GuardIan is active")
            .setContentText("Your parent can see you're safe 🛡️")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
