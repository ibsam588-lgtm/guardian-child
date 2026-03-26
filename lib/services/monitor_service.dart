import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLimitInfo {
  final String packageName;
  final String appName;
  final int dailyLimitInMinutes;
  final bool isBlocked;
  final bool allowTimeRequests;

  int get dailyLimitMinutes => dailyLimitInMinutes;

  AppLimitInfo({
    required this.packageName,
    required this.appName,
    required this.dailyLimitInMinutes,
    required this.isBlocked,
    this.allowTimeRequests = true,
  });
}

class MonitorService extends ChangeNotifier {
  final SharedPreferences _prefs;

  MonitorService(this._prefs);

  static const _channel = MethodChannel('com.guardian.child/monitor');
  final _battery = Battery();

  Timer? _heartbeatTimer;
  Timer? _syncTimer;
  List<AppLimitInfo> _appLimits = [];
  StreamSubscription? _limitsSubscription;
  bool _isRunning = false;
  String? _childId;
  String _lastLocation = '';

  List<AppLimitInfo> get appLimits => _appLimits;
  bool get isRunning => _isRunning;
  String get lastLocation => _lastLocation;

  String? get childId => _childId ?? _prefs.getString('paired_child_id');
  String? get parentUid => _prefs.getString('paired_parent_uid');

  Future<void> start(String childId) async {
    _childId = childId;
    await _startMonitoring();
  }

  Future<void> stop() async {
    await _stopMonitoring();
  }

  Future<void> _startMonitoring() async {
    if (_isRunning) return;
    _isRunning = true;

    try {
      await _channel.invokeMethod('startForegroundService');
    } catch (e) {
      // Service may already be running
    }

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _sendHeartbeat(),
    );

    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _syncCommunicationData(),
    );

    _sendHeartbeat();
    _syncCommunicationData();
    _listenToAppLimits();
    notifyListeners();
  }

  Future<void> _stopMonitoring() async {
    _isRunning = false;
    _heartbeatTimer?.cancel();
    _syncTimer?.cancel();
    _limitsSubscription?.cancel();
    try {
      await _channel.invokeMethod('stopForegroundService');
    } catch (e) {
      // ignore
    }
    notifyListeners();
  }

  Future<void> _sendHeartbeat() async {
    try {
      final cId = childId;
      final pUid = parentUid;
      if (cId == null || pUid == null) return;

      final batteryLevel = await _battery.batteryLevel;

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
        locationStr =
            '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
        _lastLocation = locationStr;
      } catch (e) {
        // Location may not be available
      }

      Map<String, dynamic> appUsageMap = {};
      try {
        final hasPermission =
            await _channel.invokeMethod<bool>('hasUsageStatsPermission') ??
                false;
        if (hasPermission) {
          final usage = await _channel.invokeMethod<Map>('getAppUsage');
          if (usage != null) {
            appUsageMap = Map<String, dynamic>.from(usage);
          }
        }
      } catch (e) {
        // ignore
      }

      final childDoc =
          FirebaseFirestore.instance.collection('children').doc(cId);
      await childDoc.set({
        'lastHeartbeat': FieldValue.serverTimestamp(),
        'batteryLevel': batteryLevel / 100.0,
        'isOnline': true,
        'lastLat': lat,
        'lastLng': lng,
        'lastLocation': locationStr,
      }, SetOptions(merge: true));

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
      final cId = childId;
      final pUid = parentUid;
      if (cId == null || pUid == null) return;

      final childDoc =
          FirebaseFirestore.instance.collection('children').doc(cId);

      try {
        final calls = await _channel.invokeMethod<List>('getCallLog');
        if (calls != null && calls.isNotEmpty) {
          final callList = calls
              .map((c) => Map<String, dynamic>.from(c as Map))
              .toList();
          await childDoc.collection('calls').doc('recent').set({
            'entries': callList.take(30).toList(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      } catch (e) {
        // Call log permission may not be granted
      }

      try {
        final messages = await _channel.invokeMethod<List>('getSmsLog');
        if (messages != null && messages.isNotEmpty) {
          final msgList = messages
              .map((m) => Map<String, dynamic>.from(m as Map))
              .toList();
          await childDoc.collection('messages').doc('recent').set({
            'entries': msgList.take(30).toList(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      } catch (e) {
        // SMS permission may not be granted
      }

      try {
        final history =
            await _channel.invokeMethod<List>('getBrowserHistory');
        if (history != null && history.isNotEmpty) {
          final histList = history
              .map((h) => Map<String, dynamic>.from(h as Map))
              .toList();
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
    final cId = childId;
    if (cId == null) return;

    _limitsSubscription?.cancel();
    _limitsSubscription = FirebaseFirestore.instance
        .collection('children')
        .doc(cId)
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
      notifyListeners();
    });
  }

  /// Submit a time extension request to the parent.
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
      await FirebaseFirestore.instance
          .collection('children')
          .doc(childId)
          .collection('time_requests')
          .add({
        'packageName': packageName,
        'appName': appName,
        'requestedMinutes': requestedMinutes,
        'childName': childName,
        'childNote': childNote,
        'status': 'pending',
        'parentUid': parentUid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Watch a time request for status changes.
  Stream<Map<String, dynamic>?> watchTimeRequest(String requestId) {
    final cId = childId;
    if (cId == null) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection('children')
        .doc(cId)
        .collection('time_requests')
        .doc(requestId)
        .snapshots()
        .map((snap) => snap.data());
  }

  Future<bool> hasUsageStatsPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasUsageStatsPermission') ??
          false;
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
      return await _channel
              .invokeMethod<bool>('hasAccessibilityPermission') ??
          false;
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
      final cId = childId;
      if (cId == null) return;
      await FirebaseFirestore.instance
          .collection('children')
          .doc(cId)
          .update({'isOnline': false});
    } catch (e) {
      // ignore
    }
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _syncTimer?.cancel();
    _limitsSubscription?.cancel();
    super.dispose();
  }
}

