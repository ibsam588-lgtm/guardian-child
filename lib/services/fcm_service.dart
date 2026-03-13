import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'pairing_service.dart';

class FcmService {
  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> init(BuildContext context) async {
    // Request permission
    await _fcm.requestPermission(alert: true, badge: true, sound: true);

    // Get token and save to Firestore
    final token = await _fcm.getToken();
    if (token != null) {
      _saveToken(context, token);
    }

    // Token refresh
    _fcm.onTokenRefresh.listen((newToken) => _saveToken(context, newToken));

    // Foreground messages
    FirebaseMessaging.onMessage.listen((msg) {
      final notification = msg.notification;
      if (notification != null) {
        debugPrint('FCM foreground: ${notification.title}');
        // In a real app show an in-app banner here
      }
    });
  }

  Future<void> _saveToken(BuildContext context, String token) async {
    final pairing = context.read<PairingService>();
    if (pairing.childId == null) return;

    await _db.collection('children').doc(pairing.childId).update({
      'fcmToken': token,
    });
  }
}
