package com.guardian.child

import android.app.ForegroundServiceStartNotAllowedException
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters

class ServiceWatchdogWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

    companion object {
        private const val TAG = "ServiceWatchdogWorker"
    }

    override fun doWork(): Result {
        Log.d(TAG, "Watchdog fired — ensuring MonitorService is running")
        val intent = Intent(applicationContext, MonitorService::class.java)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(intent)
            } else {
                applicationContext.startService(intent)
            }
            Log.d(TAG, "MonitorService start requested successfully")
            Result.success()
        } catch (e: Exception) {
            // On Android 12+, ForegroundServiceStartNotAllowedException is thrown
            // when trying to start a foreground service from background. Fall back
            // to a regular startService — the service will promote itself if able.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
                && e is ForegroundServiceStartNotAllowedException) {
                Log.w(TAG, "ForegroundServiceStartNotAllowedException — trying startService fallback")
                return try {
                    applicationContext.startService(intent)
                    Result.success()
                } catch (e2: Exception) {
                    Log.e(TAG, "startService fallback also failed: ${e2.message}")
                    Result.retry()
                }
            }
            Log.w(TAG, "Could not start MonitorService: ${e.message}")
            Result.retry()
        }
    }
}
