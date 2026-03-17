import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'pairing_service.dart';

class FcmService {
  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String? _childId;

  Future<void> init(BuildContext context) async {
    // Request permission
    await _fcm.requestPermission(alert: true, badge: true, sound: true);

    // Cache the childId so we don't need context later
    final pairing = context.read<PairingService>();
    _childId = pairing.childId;

    // Get token and save to Firestore
    final token = await _fcm.getToken();
    if (token != null) {
      _saveToken(token);
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
  }

  Future<void> _saveToken(String token) async {
    if (_childId == null) return;

    try {
      await _db.collection('children').doc(_childId).update({
        'fcmToken': token,
      });
    } catch (e) {
      debugPrint('FCM: failed to save token: $e');
    }
  }
}
