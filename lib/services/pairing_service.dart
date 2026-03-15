import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:battery_plus/battery_plus.dart';

const _kChildIdKey = 'paired_child_id';
const _kParentUidKey = 'paired_parent_uid';
const _kChildNameKey = 'paired_child_name';

class PairingService extends ChangeNotifier {
  final SharedPreferences _prefs;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  PairingService(this._prefs);

  bool get isPaired => _prefs.getString(_kChildIdKey) != null;
  String? get childId => _prefs.getString(_kChildIdKey);
  String? get parentUid => _prefs.getString(_kParentUidKey);
  String? get childName => _prefs.getString(_kChildNameKey);

  /// The parent app generates a 6-digit code and stores a doc in
  /// Firestore pairing_codes/{code}. Child reads it, links itself.
  Future<PairingResult> pairWithCode(String code) async {
    try {
      final codeDoc = await _db
          .collection('pairing_codes')
          .doc(code.trim().toUpperCase())
          .get();

      if (!codeDoc.exists) {
        return PairingResult.notFound;
      }

      final data = codeDoc.data()!;

      // Check expiry (codes valid for 10 minutes)
      final expiresAt = (data['expiresAt'] as Timestamp).toDate();
      if (DateTime.now().isAfter(expiresAt)) {
        return PairingResult.expired;
      }

      // Already used?
      if (data['used'] == true) {
        return PairingResult.alreadyUsed;
      }

      final childId = data['childId'] as String;
      final parentUid = data['parentUid'] as String;
      final childName = data['childName'] as String;

      // Get device info
      final deviceInfo = DeviceInfoPlugin();
      final android = await deviceInfo.androidInfo;
      final deviceName = '${android.brand} ${android.model}';

      // Get battery
      final battery = Battery();
      final batteryLevel = await battery.batteryLevel / 100.0;

      // Use set+merge so it works even if doc structure changed
      await _db.collection('children').doc(childId).set({
        'deviceId': android.id,
        'deviceName': deviceName,
        'isOnline': true,
        'lastSeen': FieldValue.serverTimestamp(),
        'batteryLevel': batteryLevel,
      }, SetOptions(merge: true));

      // Mark code as used
      await _db.collection('pairing_codes').doc(code.trim().toUpperCase()).update({
        'used': true,
        'usedAt': FieldValue.serverTimestamp(),
      });

      // Persist pairing locally
      await _prefs.setString(_kChildIdKey, childId);
      await _prefs.setString(_kParentUidKey, parentUid);
      await _prefs.setString(_kChildNameKey, childName);

      notifyListeners();
      return PairingResult.success;
    } catch (e) {
      debugPrint('Pairing error: $e');
      return PairingResult.error;
    }
  }

  /// Unpair — called from settings if child wants to reset
  Future<void> unpair() async {
    if (childId != null) {
      await _db.collection('children').doc(childId).update({'isOnline': false});
    }
    await _prefs.remove(_kChildIdKey);
    await _prefs.remove(_kParentUidKey);
    await _prefs.remove(_kChildNameKey);
    notifyListeners();
  }
}

enum PairingResult { success, notFound, expired, alreadyUsed, error }

extension PairingResultMessage on PairingResult {
  String get message {
    switch (this) {
      case PairingResult.success:      return 'Paired successfully!';
      case PairingResult.notFound:     return 'Code not found. Please check and try again.';
      case PairingResult.expired:      return 'This code has expired. Ask your parent for a new one.';
      case PairingResult.alreadyUsed:  return 'This code has already been used.';
      case PairingResult.error:        return 'Something went wrong. Please try again.';
    }
  }
}
