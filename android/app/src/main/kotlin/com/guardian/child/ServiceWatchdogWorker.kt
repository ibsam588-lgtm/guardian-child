package com.guardian.child

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
        return try {
            val intent = Intent(applicationContext, MonitorService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(intent)
            } else {
                applicationContext.startService(intent)
            }
            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "Could not start MonitorService: ${e.message}")
            Result.failure()
        }
    }
}
