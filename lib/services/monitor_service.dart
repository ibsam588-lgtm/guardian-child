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
    isBlocked: (d['dailyLimitMinutes'] as int?) == 0 && (d['isEnabled'] as bool? ?? true),
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

    // Start foreground service — gracefully ignore if native side isn't ready
    _startForegroundService();

    // Heartbeat every 30 seconds
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_sendHeartbeat(childId)),
    );

    _listenToAppLimits(childId);

    // First heartbeat immediately
    unawaited(_sendHeartbeat(childId));
  }

  Future<void> _startForegroundService() async {
    try {
      await _channel.invokeMethod<void>('startForegroundService');
    } on MissingPluginException {
      // Native side not implemented — that's OK, location still works
      debugPrint('MonitorService: foreground service channel not available');
    } catch (e) {
      debugPrint('MonitorService: foreground service error: $e');
    }
  }

  void stop() {
    _heartbeatTimer?.cancel();
    _limitsSubscription?.cancel();
    _isRunning = false;
    _stopForegroundService();
  }

  Future<void> _stopForegroundService() async {
    try {
      await _channel.invokeMethod<void>('stopForegroundService');
    } catch (_) {}
  }

  Future<void> _sendHeartbeat(String childId) async {
    try {
      final batteryLevel = await _battery.batteryLevel;
      String locationStr = _lastLocation;
      double? lat, lng;

      // Request location permission if not granted
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        try {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
          ).timeout(const Duration(seconds: 10));
          lat = pos.latitude;
          lng = pos.longitude;

          try {
            final marks = await placemarkFromCoordinates(pos.latitude, pos.longitude)
                .timeout(const Duration(seconds: 5));
            if (marks.isNotEmpty) {
              final m = marks.first;
              locationStr = [
                m.street, m.subLocality, m.locality, m.administrativeArea,
              ].where((s) => s != null && s.isNotEmpty).take(2).join(', ');
              if (locationStr.isEmpty) {
                locationStr = '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
              }
            }
          } catch (_) {
            locationStr = '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
          }

          if (locationStr.isNotEmpty) _lastLocation = locationStr;
        } catch (e) {
          debugPrint('Location error: $e');
        }
      }

      final Map<String, dynamic> update = {
        'isOnline': true,
        'lastSeen': FieldValue.serverTimestamp(),
        'batteryLevel': batteryLevel / 100.0,
        'lastLocation': locationStr,
      };
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
      _appLimits = snap.docs.map((d) => AppLimitInfo.fromMap(d.data())).toList();
      notifyListeners();
    }, onError: (e) => debugPrint('App limits error: $e'));
  }
}
