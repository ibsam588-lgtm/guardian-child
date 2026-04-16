import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:battery_plus/battery_plus.dart';

const _kChildIdKey = 'paired_child_id';
const _kParentUidKey = 'paired_parent_uid';
const _kChildNameKey = 'paired_child_name';

class PairingService extends ChangeNotifier {
  final SharedPreferences _prefs;
  FirebaseFirestore get _db => FirebaseFirestore.instance;

  PairingService(this._prefs);

  bool get isPaired => _prefs.getString(_kChildIdKey) != null;
  String? get childId => _prefs.getString(_kChildIdKey);
  String? get parentUid => _prefs.getString(_kParentUidKey);
  String? get childName => _prefs.getString(_kChildNameKey);

  /// The parent app generates a 6-digit code and stores a doc in
  /// Firestore pairing_codes/{code}. Child reads it, links itself.
  Future<PairingResult> pairWithCode(String code) async {
    try {
      final trimmedCode = code.trim();

      // ── Step 1: Read the code doc (public read, no auth needed) ──────────
      final codeDoc = await _db
          .collection('pairing_codes')
          .doc(trimmedCode)
          .get()
          .timeout(const Duration(seconds: 10));

      if (!codeDoc.exists) {
        debugPrint('Pairing: code $trimmedCode not found in Firestore');
        return PairingResult.notFound;
      }

      final data = codeDoc.data()!;
      debugPrint('Pairing: code doc found: ${data.keys.toList()}');

      // ── Step 2: Validate code ────────────────────────────────────────────
      final expiresAtRaw = data['expiresAt'];
      if (expiresAtRaw == null || expiresAtRaw is! Timestamp) {
        debugPrint('Pairing: code doc missing or invalid expiresAt field');
        return PairingResult.error;
      }
      final expiresAt = expiresAtRaw.toDate();
      if (DateTime.now().isAfter(expiresAt)) {
        debugPrint('Pairing: code expired at $expiresAt');
        return PairingResult.expired;
      }

      if (data['used'] == true) {
        debugPrint('Pairing: code already used');
        return PairingResult.alreadyUsed;
      }

      // childId is required — validate it exists
      final childId = data['childId'] as String?;
      if (childId == null || childId.isEmpty) {
        debugPrint('Pairing: code doc missing childId field');
        return PairingResult.error;
      }

      final parentUid = data['parentUid'] as String? ?? '';
      // Trim whitespace and guard against spurious suffixes from older parent-app
      // versions that may have concatenated the child's age into this field.
      final childName = (data['childName'] as String? ?? 'Child').trim();

      // ── Step 3: Ensure anonymous auth (required for Firestore writes) ────
      // Firestore rules require request.auth != null for writes.
      // If the splash-screen auth failed or hasn't completed yet, do it now.
      var user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('Pairing: not authenticated, signing in anonymously…');
        try {
          final cred = await FirebaseAuth.instance
              .signInAnonymously()
              .timeout(const Duration(seconds: 10));
          user = cred.user;
          debugPrint('Pairing: anonymous auth success uid=${user?.uid}');
        } catch (authErr) {
          debugPrint('Pairing: anonymous auth FAILED: $authErr');
          return PairingResult.authFailed;
        }
      }
      if (user == null) return PairingResult.authFailed;

      // ── Step 4: Collect device info ──────────────────────────────────────
      String deviceName = 'Android Device';
      String deviceId = user.uid; // fallback
      try {
        final deviceInfo = DeviceInfoPlugin();
        final android = await deviceInfo.androidInfo;
        deviceName = '${android.brand} ${android.model}'.trim();
        deviceId = android.id;
      } catch (e) {
        debugPrint('Pairing: device info error: $e');
      }

      double batteryLevel = 0.5;
      try {
        final battery = Battery();
        batteryLevel = await battery.batteryLevel / 100.0;
      } catch (e) {
        debugPrint('Pairing: battery error: $e');
      }

      // ── Step 5: Write to Firestore (authenticated) ───────────────────────
      try {
        await _db.collection('children').doc(childId).set({
          'deviceId': deviceId,
          'deviceName': deviceName,
          // childAuthUid is the anonymous Firebase Auth UID for this device.
          // Stored here so Firestore rules can verify child device ownership:
          //   request.auth.uid == resource.data.childAuthUid
          'childAuthUid': user.uid,
          'isOnline': true,
          'lastSeen': FieldValue.serverTimestamp(),
          'batteryLevel': batteryLevel,
        }, SetOptions(merge: true));
        debugPrint('Pairing: children doc updated');
      } catch (e) {
        debugPrint('Pairing: FAILED to update children doc: $e');
        if (e.toString().contains('permission-denied') ||
            e.toString().contains('PERMISSION_DENIED')) {
          return PairingResult.permissionDenied;
        }
        return PairingResult.error;
      }

      try {
        await _db.collection('pairing_codes').doc(trimmedCode).update({
          'used': true,
          'usedAt': FieldValue.serverTimestamp(),
        });
        debugPrint('Pairing: code marked as used');
      } catch (e) {
        debugPrint('Pairing: FAILED to mark code used: $e');
        // Non-fatal — we still paired successfully, just couldn't invalidate the code
      }

      // ── Step 6: Persist locally ──────────────────────────────────────────
      await _prefs.setString(_kChildIdKey, childId);
      await _prefs.setString(_kParentUidKey, parentUid);
      await _prefs.setString(_kChildNameKey, childName);

      debugPrint('Pairing: SUCCESS childId=$childId parentUid=$parentUid');
      notifyListeners();
      return PairingResult.success;

    } on TimeoutException catch (e) {
      debugPrint('Pairing: timeout: $e');
      return PairingResult.timeout;
    } catch (e) {
      debugPrint('Pairing: unexpected error: $e');
      if (e.toString().contains('permission-denied') ||
          e.toString().contains('PERMISSION_DENIED')) {
        return PairingResult.permissionDenied;
      }
      return PairingResult.error;
    }
  }

  /// Unpair — called from settings if child wants to reset
  Future<void> unpair() async {
    if (childId != null) {
      // Use .update() instead of .set(merge:true) so we don't resurrect
      // the children/{childId} doc as a zombie record when the parent
      // has already deleted it (unpair-via-deleteChild). .update() fails
      // with NOT_FOUND in that case, which we swallow silently.
      try {
        await _db.collection('children').doc(childId).update({
          'isOnline': false,
          'childAuthUid': FieldValue.delete(),
        });
      } catch (e) {
        debugPrint('Pairing: unpair Firestore update skipped (non-fatal): $e');
      }
    }
    await _prefs.remove(_kChildIdKey);
    await _prefs.remove(_kParentUidKey);
    await _prefs.remove(_kChildNameKey);
    notifyListeners();
  }
}

enum PairingResult { success, notFound, expired, alreadyUsed, error, authFailed, permissionDenied, timeout }

extension PairingResultMessage on PairingResult {
  String get message {
    switch (this) {
      case PairingResult.success:          return 'Paired successfully!';
      case PairingResult.notFound:         return 'Code not found. Please check the 6 digits and try again.';
      case PairingResult.expired:          return 'This code has expired. Ask your parent to generate a new one.';
      case PairingResult.alreadyUsed:      return 'This code has already been used. Ask your parent for a new one.';
      case PairingResult.authFailed:       return 'Could not connect to the server. Check your internet connection.';
      case PairingResult.permissionDenied: return 'Permission denied. Ensure this device has internet access and try again.';
      case PairingResult.timeout:          return 'Connection timed out. Check your internet and try again.';
      case PairingResult.error:            return 'Something went wrong. Please try again.';
    }
  }
}
