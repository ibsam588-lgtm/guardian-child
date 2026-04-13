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
    try {
      await _db.collection('children').doc(childId).set({
        'deviceId': deviceId,
        'deviceName': deviceName,
        'isOnline': true,
        'lastSeen': FieldValue.serverTimestamp(),
        'batteryLevel': batteryLevel,
        'fcmToken': '',  // updated separately by FcmService
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('AuthService: updateChildDevice error: $e');
    }
  }

  /// Called when app goes background — mark child offline
  Future<void> setOffline(String childId) async {
    try {
      await _db.collection('children').doc(childId).set({
        'isOnline': false,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('AuthService: setOffline error: $e');
    }
  }
}
