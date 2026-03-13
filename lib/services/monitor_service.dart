import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLimitInfo {
  final String packageName;
  final String appName;
  final int dailyLimitMinutes;
  final bool isBlocked;
  final bool allowTimeRequests;

  AppLimitInfo({
    required this.packageName,
    required this.appName,
    required this.dailyLimitMinutes,
    required this.isBlocked,
    required this.allowTimeRequests,
  });

  factory AppLimitInfo.fromMap(Map<String, dynamic> d) => AppLimitInfo(
    packageName: d['packageName'] ?? '',
    appName: d['appName'] ?? '',
    dailyLimitMinutes: d['dailyLimitMinutes'] ?? 60,
    isBlocked: d['dailyLimitMinutes'] == 0 && (d['isEnabled'] ?? true),
    allowTimeRequests: d['allowTimeRequests'] ?? true,
  );
}

class MonitorService extends ChangeNotifier {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final Battery _battery = Battery();

  // Platform channel to communicate with native foreground service
  static const _channel = MethodChannel('com.guardian.child/monitor');

  Timer? _heartbeatTimer;
  StreamSubscription? _limitsSubscription;

  List<AppLimitInfo> _appLimits = [];
  List<AppLimitInfo> get appLimits => _appLimits;

  bool _isRunning = false;
  String _lastLocation = 'Unknown';
  String get lastLocation => _lastLocation;

  MonitorService(SharedPreferences _);

  /// Start monitoring — called after pairing is confirmed
  void start(String childId) {
    if (_isRunning) return;
    _isRunning = true;

    // Start native foreground service (fire-and-forget)
    _channel.invokeMethod('startForegroundService').catchError((_) {});

    // 30-second heartbeat: location + battery
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_sendHeartbeat(childId)),
    );

    // Listen to app limits pushed down from parent
    _listenToAppLimits(childId);

    // Send first heartbeat immediately (fire-and-forget)
    unawaited(_sendHeartbeat(childId));
  }

  void stop() {
    _heartbeatTimer?.cancel();
    _limitsSubscription?.cancel();
    _isRunning = false;
    _channel.invokeMethod('stopForegroundService').catchError((_) {});
  }

  Future<void> _sendHeartbeat(String childId) async {
    try {
      final battery = await _battery.batteryLevel;
      String locationStr = _lastLocation;
      double? lat, lng;

      // Location
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        try {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: LocationSettings(accuracy: LocationAccuracy.medium),
          );
          lat = pos.latitude;
          lng = pos.longitude;

          // Reverse geocode
          try {
            final placemarks =
                await placemarkFromCoordinates(pos.latitude, pos.longitude);
            if (placemarks.isNotEmpty) {
              final p = placemarks.first;
              locationStr = [p.street, p.locality, p.administrativeArea]
                  .where((s) => s != null && s.isNotEmpty)
                  .join(', ');
            }
          } catch (_) {
            locationStr =
                '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
          }
          _lastLocation = locationStr;
        } catch (_) {
          // Location timeout — still send battery update
        }
      }

      // Write to Firestore
      final update = <String, dynamic>{
        'isOnline': true,
        'lastSeen': FieldValue.serverTimestamp(),
        'batteryLevel': battery / 100.0,
      };
      if (locationStr.isNotEmpty && locationStr != 'Unknown') {
        update['lastLocation'] = locationStr;
      }
      if (lat != null && lng != null) {
        update['lastLat'] = lat;
        update['lastLng'] = lng;
      }

      await _db.collection('children').doc(childId).update(update);
      notifyListeners();
    } catch (e) {
      debugPrint('Heartbeat error: $e');
    }
  }

  void _listenToAppLimits(String childId) {
    _limitsSubscription = _db
        .collection('children')
        .doc(childId)
        .collection('appLimits')
        .snapshots()
        .listen((snap) {
      _appLimits =
          snap.docs.map((d) => AppLimitInfo.fromMap(d.data())).toList();
      notifyListeners();
    });
  }

  /// Submit a time request to Firestore
  Future<bool> submitTimeRequest({
    required String childId,
    required String childName,
    required String parentUid,
    required String appName,
    required String packageName,
    required int requestedMinutes,
    String? childNote,
  }) async {
    try {
      final now = DateTime.now();
      await _db.collection('timeRequests').add({
        'childId': childId,
        'childName': childName,
        'parentUid': parentUid,
        'appName': appName,
        'packageName': packageName,
        'appIconColor': '#6C63FF',
        'requestedMinutes': requestedMinutes,
        'childNote': childNote,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(
            now.add(const Duration(minutes: 10))),
      });
      return true;
    } catch (e) {
      debugPrint('TimeRequest error: $e');
      return false;
    }
  }

  /// Watch a specific time request for parent response
  Stream<Map<String, dynamic>?> watchTimeRequest(String requestId) {
    return _db
        .collection('timeRequests')
        .doc(requestId)
        .snapshots()
        .map((s) => s.data());
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
