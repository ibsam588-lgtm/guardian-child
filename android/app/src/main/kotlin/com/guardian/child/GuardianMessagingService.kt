package com.guardian.child

import android.util.Log
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService

/**
 * Extends Flutter's FCM service to intercept siren commands at the native layer.
 *
 * This ensures the siren plays even when the child app is backgrounded or fully
 * killed — scenarios where the Dart [CommandService] Firestore listener is not
 * running and MethodChannels are unavailable.
 *
 * For all other messages (and after handling siren), super.onMessageReceived()
 * forwards the message to Flutter's normal pipeline so foreground notifications
 * and the Dart onMessage / onBackgroundMessage handlers still work.
 */
class GuardianMessagingService : FlutterFirebaseMessagingService() {

    companion object {
        private const val TAG = "GuardianMsgService"
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val type = message.data["type"]
        Log.d(TAG, "FCM received, type=$type")

        when (type) {
            "siren" -> {
                Log.d(TAG, "FCM siren command — starting SirenService")
                SirenService.start(this)
            }
            "siren_stop" -> {
                Log.d(TAG, "FCM siren_stop command — stopping SirenService")
                SirenService.stop(this)
            }
        }

        // Always forward to Flutter so the Dart layer can handle other messages
        // and update UI / Firestore state as needed.
        super.onMessageReceived(message)
    }
}
