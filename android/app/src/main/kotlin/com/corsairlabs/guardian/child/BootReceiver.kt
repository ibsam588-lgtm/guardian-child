package com.corsairlabs.guardian.child

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == "android.intent.action.QUICKBOOT_POWERON") {

            // Only restart if the app was previously paired
            val prefs: SharedPreferences =
                context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val isPaired = prefs.contains("flutter.paired_child_id")

            if (isPaired) {
                MonitorService.start(context)
            }
        }
    }
}
