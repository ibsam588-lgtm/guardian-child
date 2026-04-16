import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'pairing_service.dart';

class FcmService {
  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String? _childId;

  Future<void> init(PairingService pairing) async {
    try {
      _childId = pairing.childId;

      if (_childId == null) {
        debugPrint('FCM: skipping init');
        return;
      }

      await _fcm.requestPermission(alert: true, badge: true, sound: true);

      final token = await _fcm.getToken();
      if (token != null) {
        await _saveToken(token);
      }

      _fcm.onTokenRefresh.listen(
        (newToken) => _saveToken(newToken),
        onError: (e) => debugPrint('FCM: token refresh error: $e'),
      );

      FirebaseMessaging.onMessage.listen((msg) {
        // Handle siren commands delivered via FCM data payload
        final type = msg.data['type'] as String?;
        if (type == 'siren') {
          const channel = MethodChannel('com.guardian.child/monitor');
          channel.invokeMethod<void>('playSiren').catchError((e) {
            debugPrint('FCM: playSiren error: $e');
          });
        } else if (type == 'siren_stop') {
          const channel = MethodChannel('com.guardian.child/monitor');
          channel.invokeMethod<void>('stopSiren').catchError((e) {
            debugPrint('FCM: stopSiren error: $e');
          });
        }

        final notification = msg.notification;
        if (notification != null) {
          debugPrint('FCM foreground: ${notification.title}');
        }
      });
    } catch (e, stack) {
      debugPrint('FCM init error: $e');
      debugPrint('FCM init stack: $stack');
    }
  }

  Future<void> _saveToken(String token) async {
    if (_childId == null) return;

    try {
      await _db.collection('children').doc(_childId).set({
        'fcmToken': token,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('FCM: failed to save token: $e');
    }
  }
}
