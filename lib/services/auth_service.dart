import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService extends ChangeNotifier {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  bool get isSignedIn => currentUser != null;

  /// Sign in anonymously — child devices don't need an account.
  /// The link to the parent is done via the pairing code.
  Future<UserCredential?> signInAnonymously() async {
    try {
      final cred = await _auth.signInAnonymously();
      return cred;
    } catch (e) {
      debugPrint('Auth error: $e');
      return null;
    }
  }

  /// Update the child device document in Firestore after pairing
  Future<void> updateChildDevice({
    required String childId,
    required String deviceId,
    required String deviceName,
    required double batteryLevel,
  }) async {
    if (currentUser == null) return;
    await _db.collection('children').doc(childId).update({
      'deviceId': deviceId,
      'deviceName': deviceName,
      'isOnline': true,
      'lastSeen': FieldValue.serverTimestamp(),
      'batteryLevel': batteryLevel,
      'fcmToken': '',  // updated separately by FcmService
    });
  }

  /// Called when app goes background — mark child offline
  Future<void> setOffline(String childId) async {
    await _db.collection('children').doc(childId).update({
      'isOnline': false,
      'lastSeen': FieldValue.serverTimestamp(),
    });
  }
}
