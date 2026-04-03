import 'package:flutter/foundation.dart';
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

      _fcm.onTokenRefresh.listen((newToken) => _saveToken(newToken));

      FirebaseMessaging.onMessage.listen((msg) {
        final notification = msg.notification;
        if (notification != null) {
          debugPrint('FCM foreground: \${notification.title}');
        }
      });
    } catch (e, stack) {
      debugPrint('FCM init error: \$e');
      debugPrint('FCM init stack: \$stack');
    }
  }

  Future<void> _saveToken(String token) async {
    if (_childId == null) return;

    try {
      await _db.collection('children').doc(_childId).set({
        'fcmToken': token,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('FCM: failed to save token: \$e');
    }
  }
}
