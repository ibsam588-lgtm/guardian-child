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
      // Get childId directly from the passed service
      _childId = pairing.childId;

      // If no childId yet (not paired), skip FCM setup entirely
      if (_childId == null) {
        debugPrint('FCM: skipping init — child not paired yet');
        return;
      }

      // Request permission
      await _fcm.requestPermission(alert: true, badge: true, sound: true);

      // Get token and save to Firestore
      final token = await _fcm.getToken();
      if (token != null) {
        await _saveToken(token);
      }

      // Token refresh — use cached childId, not context
      _fcm.onTokenRefresh.listen((newToken) => _saveToken(newToken));

      // Foreground messages
      FirebaseMessaging.onMessage.listen((msg) {
        final notification = msg.notification;
        if (notification != null) {
          debugPrint('FCM foreground: ${notification.title}');
          // In a real app show an in-app banner here
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
