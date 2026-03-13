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
        packageName: d['packageName'] as String? ?? '',
        appName: d['appName'] as String? ?? '',
        dailyLimitMinutes: d['dailyLimitMinutes'] as int? ?? 60,
        isBlocked: (d['dailyLimitMinutes'] as int?) == 0 &&
            (d['isEnabled'] as bool? ?? true),
        allowTimeRequests: d['allowTimeRequests'] as bool? ?? true,
      );
}

class MonitorService extends ChangeNotifier {
  static const _channel = MethodChannel('com.guardian.child/monitor');

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final Battery _battery = Battery();

  Timer? _heartbeatTimer;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _limitsSubscription;

  List<AppLimitInfo> _appLimits = [];
  List<AppLimitInfo> get appLimits => _appLimits;

  bool _isRunning = false;
  String _lastLocation = 'Unknown';
  String get lastLocation => _lastLocation;

  // ignore: avoid_unused_constructor_parameters
  MonitorService(SharedPreferences _);

  void start(String childId) {
    if (_isRunning) return;
    _isRunning = true;

    // Tell native Android to start the foreground service
    _channel.invokeMethod<void>('startForegroundService').ignore();

    // Heartbeat every 30 seconds
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_sendHeartbeat(childId)),
    );

    _listenToAppLimits(childId);

    // First heartbeat immediately
    unawaited(_sendHeartbeat(childId));
  }

  void stop() {
    _heartbeatTimer?.cancel();
    _limitsSubscription?.cancel();
    _isRunning = false;
    _channel.invokeMethod<void>('stopForegroundService').ignore();
  }

  Future<void> _sendHeartbeat(String childId) async {
    try {
      final batteryLevel = await _battery.batteryLevel;
      String locationStr = _lastLocation;
      double? lat, lng;

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        try {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: LocationSettings(
              accuracy: LocationAccuracy.medium,
            ),
          );
          lat = pos.latitude;
          lng = pos.longitude;

          try {
            final marks =
                await placemarkFromCoordinates(pos.latitude, pos.longitude);
            if (marks.isNotEmpty) {
              final p = marks.first;
              locationStr = [p.street, p.locality, p.administrativeArea]
                  .whereType<String>()
                  .where((s) => s.isNotEmpty)
                  .join(', ');
            }
          } catch (_) {
            locationStr =
                '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
          }
          _lastLocation = locationStr;
        } catch (_) {
          // Location unavailable — still send battery
        }
      }

      final update = <String, dynamic>{
        'isOnline': true,
        'lastSeen': FieldValue.serverTimestamp(),
        'batteryLevel': batteryLevel / 100.0,
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
