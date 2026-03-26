import 'dart:async';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pairing_service.dart';

class AppLimitInfo {
  final String packageName;
  final String appName;
  final int dailyLimitInMinutes;
  final bool isBlocked;
  final bool allowTimeRequests;

  AppLimitInfo({
    required this.packageName,
    required this.appName,
    required this.dailyLimitInMinutes,
    required this.isBlocked,
    this.allowTimeRequests = true,
  });
}

class MonitorService {
  static final MonitorService _instance = MonitorService._internal();
  factory MonitorService() => _instance;
  MonitorService._internal();

  static const _channel = MethodChannel('com.guardian.child/monitor');
  final _battery = Battery();
  Timer? _heartbeatTimer;
  Timer? _syncTimer;
  List<AppLimitInfo> _appLimits = [];
  StreamSubscription? _limitsSubscription;
  bool _isRunning = false;

  List<AppLimitInfo> get appLimits => _appLimits;
  bool get isRunning => _isRunning;

  Future<void> startMonitoring() async {
    if (_isRunning) return;
    _isRunning = true;

    // Start native foreground service
    try {
      await _channel.invokeMethod('startForegroundService');
    } catch (e) {
      // Service may already be running
    }

    // Heartbeat every 30 seconds (battery, location, online)
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _sendHeartbeat(),
    );

    // Sync call/SMS/browser data every 5 minutes
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _syncCommunicationData(),
    );

    // Initial heartbeat and sync
    _sendHeartbeat();
    _syncCommunicationData();

    // Listen to app limits from parent
    _listenToAppLimits();
  }

  Future<void> stopMonitoring() async {
    _isRunning = false;
    _heartbeatTimer?.cancel();
    _syncTimer?.cancel();
    _limitsSubscription?.cancel();
    try {
      await _channel.invokeMethod('stopForegroundService');
    } catch (e) {
      // ignore
    }
  }

  Future<void> _sendHeartbeat() async {
    try {
      final pairing = PairingService();
      final childId = pairing.childId;
      final parentUid = pairing.parentUid;
      if (childId == null || parentUid == null) return;

      // Get battery level
      final batteryLevel = await _battery.batteryLevel;

      // Get location
      double? lat;
      double? lng;
      String locationStr = '';
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 10),
          ),
        );
        lat = pos.latitude;
        lng = pos.longitude;
        locationStr = '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
      } catch (e) {
        // Location may not be available
      }

      // Get app usage
      Map<String, dynamic> appUsageMap = {};
      try {
        final hasPermission = await _channel.invokeMethod<bool>('hasUsageStatsPermission') ?? false;
        if (hasPermission) {
          final usage = await _channel.invokeMethod<Map>('getAppUsage');
          if (usage != null) {
            appUsageMap = Map<String, dynamic>.from(usage);
          }
        }
      } catch (e) {
        // ignore
      }

      // Update child document with heartbeat data
      final childDoc = FirebaseFirestore.instance.collection('children').doc(childId);
      await childDoc.set({
        'lastHeartbeat': FieldValue.serverTimestamp(),
        'batteryLevel': batteryLevel / 100.0,
        'isOnline': true,
        'lastLat': lat,
        'lastLng': lng,
        'lastLocation': locationStr,
      }, SetOptions(merge: true));

      // Write app usage to subcollection
      if (appUsageMap.isNotEmpty) {
        final usageDoc = childDoc.collection('app_usage').doc('today');
        await usageDoc.set({
          'date': DateTime.now().toIso8601String().substring(0, 10),
          'apps': appUsageMap,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      // Silently fail heartbeat
    }
  }

  Future<void> _syncCommunicationData() async {
    try {
      final pairing = PairingService();
      final childId = pairing.childId;
      final parentUid = pairing.parentUid;
      if (childId == null || parentUid == null) return;

      final childDoc = FirebaseFirestore.instance.collection('children').doc(childId);

      // Sync call log
      try {
        final calls = await _channel.invokeMethod<List>('getCallLog');
        if (calls != null && calls.isNotEmpty) {
          final callList = calls.map((c) => Map<String, dynamic>.from(c as Map)).toList();
          await childDoc.collection('calls').doc('recent').set({
            'entries': callList.take(30).toList(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      } catch (e) {
        // Call log permission may not be granted
      }

      // Sync SMS log
      try {
        final messages = await _channel.invokeMethod<List>('getSmsLog');
        if (messages != null && messages.isNotEmpty) {
          final msgList = messages.map((m) => Map<String, dynamic>.from(m as Map)).toList();
          await childDoc.collection('messages').doc('recent').set({
            'entries': msgList.take(30).toList(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      } catch (e) {
        // SMS permission may not be granted
      }

      // Sync browser history
      try {
        final history = await _channel.invokeMethod<List>('getBrowserHistory');
        if (history != null && history.isNotEmpty) {
          final histList = history.map((h) => Map<String, dynamic>.from(h as Map)).toList();
          await childDoc.collection('browser_history').doc('recent').set({
            'entries': histList.take(50).toList(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      } catch (e) {
        // Browser history may not be available
      }
    } catch (e) {
      // Silently fail sync
    }
  }

  void _listenToAppLimits() {
    final pairing = PairingService();
    final childId = pairing.childId;
    if (childId == null) return;

    _limitsSubscription?.cancel();
    _limitsSubscription = FirebaseFirestore.instance
        .collection('children')
        .doc(childId)
        .collection('app_limits')
        .snapshots()
        .listen((snap) {
      _appLimits = snap.docs.map((doc) {
        final d = doc.data();
        return AppLimitInfo(
          packageName: d['packageName'] ?? '',
          appName: d['appName'] ?? '',
          dailyLimitInMinutes: d['dailyLimitMinutes'] ?? 0,
          isBlocked: d['isBlocked'] ?? false,
          allowTimeRequests: d['allowTimeRequests'] ?? true,
        );
      }).toList();
    });
  }

  Future<bool> hasUsageStatsPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasUsageStatsPermission') ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<void> openUsageAccessSettings() async {
    try {
      await _channel.invokeMethod('openUsageAccessSettings');
    } catch (e) {
      // ignore
    }
  }

  Future<bool> hasAccessibilityPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasAccessibilityPermission') ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<void> openAccessibilitySettings() async {
    try {
      await _channel.invokeMethod('openAccessibilitySettings');
    } catch (e) {
      // ignore
    }
  }

  Future<void> setOffline() async {
    try {
      final pairing = PairingService();
      final childId = pairing.childId;
      if (childId == null) return;
      await FirebaseFirestore.instance
          .collection('children')
          .doc(childId)
          .update({'isOnline': false});
    } catch (e) {
      // ignore
    }
  }
}
