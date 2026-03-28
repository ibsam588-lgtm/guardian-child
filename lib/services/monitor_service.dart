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

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  final Battery _battery = Battery();

  Timer? _heartbeatTimer;
  Timer? _commsTimer;
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

    // Start foreground service — it will self-stop if permissions not granted
    _startForegroundService();

    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        unawaited(_sendHeartbeat(childId));
        unawaited(_reportAppUsage(childId));
      },
    );

    // Sync communications every 5 minutes
    _commsTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) {
        unawaited(_reportCommunications(childId));
      },
    );

    _listenToAppLimits(childId);
    _listenToCommands(childId);
    unawaited(_sendHeartbeat(childId));

    // Sync installed apps once on start, then every 10 minutes
    unawaited(_syncInstalledApps(childId));
    Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(_syncInstalledApps(childId));
    });

    // Sync communications once on start
    unawaited(_reportCommunications(childId));
  }

  Future<void> _startForegroundService() async {
    try {
      await _channel.invokeMethod<void>('startForegroundService');
    } on MissingPluginException {
      debugPrint('MonitorService: foreground service channel not available');
    } catch (e) {
      debugPrint('MonitorService: foreground service error: $e');
    }
  }

  void stop() {
    _heartbeatTimer?.cancel();
    _commsTimer?.cancel();
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

      LocationPermission permission = await Geolocator.checkPermission();
      // Don't request permission here — it's handled in PermissionsScreen
      // Just skip location if not granted
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        try {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings:
                const LocationSettings(accuracy: LocationAccuracy.medium),
          ).timeout(const Duration(seconds: 10));

          lat = pos.latitude;
          lng = pos.longitude;

          try {
            final marks =
                await placemarkFromCoordinates(pos.latitude, pos.longitude)
                    .timeout(const Duration(seconds: 5));
            if (marks.isNotEmpty) {
              final m = marks.first;
              locationStr = [
                m.street,
                m.subLocality,
                m.locality,
                m.administrativeArea
              ].where((s) => s != null && s.isNotEmpty).take(2).join(', ');
              if (locationStr.isEmpty) {
                locationStr =
                    '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
              }
            }
          } catch (_) {
            locationStr =
                '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
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

  /// Reads today's app usage via UsageStatsManager and writes to
  /// children/{childId}/app_usage/today as a single document with apps map.
  Future<void> _reportAppUsage(String childId) async {
    try {
      final raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('getAppUsage');
      if (raw == null || raw.isEmpty) return;

      final now = DateTime.now();
      final dateStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      // Build appName lookup from current limits list
      final limitsByPkg = {for (final l in _appLimits) l.packageName: l};

      final Map<String, dynamic> appsMap = {};
      for (final entry in raw.entries) {
        final pkg = entry.key as String? ?? '';
        final mins = (entry.value as num?)?.toInt() ?? 0;
        if (pkg.isEmpty || mins <= 0) continue;

        final limit = limitsByPkg[pkg];
        appsMap[pkg] = {
          'appName': limit?.appName ?? _prettifyPackageName(pkg),
          'minutesUsed': mins,
          'dailyLimitMinutes': limit?.dailyLimitMinutes ?? 0,
        };
      }

      if (appsMap.isNotEmpty) {
        await _db
            .collection('children')
            .doc(childId)
            .collection('app_usage')
            .doc('today')
            .set({
          'apps': appsMap,
          'date': dateStr,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    } on MissingPluginException {
      // Running in test / simulator
    } on PlatformException catch (e) {
      if (e.code != 'PERMISSION_DENIED') {
        debugPrint('App usage error: ${e.message}');
      }
    } catch (e) {
      debugPrint('App usage error: $e');
    }
  }

  String _prettifyPackageName(String pkg) {
    final parts = pkg.split('.');
    if (parts.length >= 2)
      return parts.last[0].toUpperCase() + parts.last.substring(1);
    return pkg;
  }

  /// Syncs installed apps list to children/{childId}/installed_apps/current
  Future<void> _syncInstalledApps(String childId) async {
    try {
      final raw = await _channel
          .invokeListMethod<Map<Object?, Object?>>('getInstalledApps');
      if (raw == null || raw.isEmpty) return;

      final apps = raw
          .map((app) => {
                'packageName': app['packageName'] as String? ?? '',
                'appName': app['appName'] as String? ?? '',
                'isSystem': app['isSystem'] as bool? ?? false,
              })
          .toList();

      await _db
          .collection('children')
          .doc(childId)
          .collection('installed_apps')
          .doc('current')
          .set({
        'apps': apps,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } on MissingPluginException {
      // Running in test / simulator
    } catch (e) {
      debugPrint('Installed apps sync error: $e');
    }
  }

  // ── Communication Monitoring ──────────────────────────────────────────────

  /// Reads recent call log and SMS messages and syncs to Firestore.
  /// Writes to children/{childId}/communications/today
  Future<void> _reportCommunications(String childId) async {
    try {
      // Check if we have permission first
      final hasPermission = await _channel
              .invokeMethod<bool>('hasCommsPermission') ??
          false;
      if (!hasPermission) {
        debugPrint('Comms: permissions not granted, skipping');
        return;
      }

      final now = DateTime.now();
      final dateStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      // ── Call log ──────────────────────────────────────────────────────
      List<Map<String, dynamic>> calls = [];
      try {
        final rawCalls = await _channel
            .invokeListMethod<Map<Object?, Object?>>('getCallLog');
        if (rawCalls != null) {
          calls = rawCalls.map((c) {
            return <String, dynamic>{
              'number': c['number'] as String? ?? '',
              'contactName': c['contactName'] as String?,
              'type': c['type'] as String? ?? 'unknown',
              'date': c['date'] as int? ?? 0,
              'durationSeconds': c['durationSeconds'] as int? ?? 0,
            };
          }).toList();
        }
      } on PlatformException catch (e) {
        debugPrint('Call log error: ${e.message}');
      }

      // ── SMS log ───────────────────────────────────────────────────────
      List<Map<String, dynamic>> messages = [];
      try {
        final rawSms = await _channel
            .invokeListMethod<Map<Object?, Object?>>('getSmsLog');
        if (rawSms != null) {
          messages = rawSms.map((s) {
            return <String, dynamic>{
              'address': s['address'] as String? ?? '',
              'contactName': s['contactName'] as String?,
              'type': s['type'] as String? ?? 'unknown',
              'date': s['date'] as int? ?? 0,
              // Store first 200 chars of body to avoid huge Firestore docs
              'bodyPreview': _truncate(s['body'] as String? ?? '', 200),
            };
          }).toList();
        }
      } on PlatformException catch (e) {
        debugPrint('SMS log error: ${e.message}');
      }

      // ── Write to Firestore ────────────────────────────────────────────
      if (calls.isNotEmpty || messages.isNotEmpty) {
        // Compute summary stats
        int totalCalls = calls.length;
        int totalSms = messages.length;
        int missedCalls =
            calls.where((c) => c['type'] == 'missed').length;
        int totalCallMinutes = calls.fold<int>(
            0, (sum, c) => sum + ((c['durationSeconds'] as int) ~/ 60));

        await _db
            .collection('children')
            .doc(childId)
            .collection('communications')
            .doc('today')
            .set({
          'date': dateStr,
          'updatedAt': FieldValue.serverTimestamp(),
          'summary': {
            'totalCalls': totalCalls,
            'totalSms': totalSms,
            'missedCalls': missedCalls,
            'totalCallMinutes': totalCallMinutes,
          },
          'calls': calls,
          'messages': messages,
        });

        debugPrint(
            'Comms: synced $totalCalls calls and $totalSms messages');
      }
    } on MissingPluginException {
      // Running in test / simulator — native channels not available
    } catch (e) {
      debugPrint('Communications sync error: $e');
    }
  }

  String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
  }

  /// Listens for parent commands (e.g., live_listen)
  void _listenToCommands(String childId) {
    _db
        .collection('children')
        .doc(childId)
        .collection('commands')
        .doc('live_listen')
        .snapshots()
        .listen((snap) {
      final data = snap.data();
      if (data == null) return;
      final action = data['action'] as String? ?? '';
      if (action == 'start') {
        _handleLiveListenStart(childId, data);
      } else if (action == 'stop') {
        _handleLiveListenStop(childId);
      }
    }, onError: (e) => debugPrint('Commands listener error: $e'));
  }

  void _handleLiveListenStart(
      String childId, Map<String, dynamic> data) {
    // Write an acknowledgment to audio_clips so parent knows we received the command
    _db
        .collection('children')
        .doc(childId)
        .collection('audio_clips')
        .add({
      'status': 'recording',
      'createdAt': FieldValue.serverTimestamp(),
      'parentUid': data['parentUid'],
      'durationSeconds': data['durationSeconds'] ?? 60,
    });
    debugPrint('Live listen: started recording');
    // TODO: Implement actual audio recording via platform channel
  }

  void _handleLiveListenStop(String childId) {
    debugPrint('Live listen: stopped');
    // TODO: Stop audio recording
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
    }, onError: (e) => debugPrint('App limits error: $e'));
  }

  // ── Accessibility ─────────────────────────────────────────────────────────

  /// Returns true if the app has accessibility service permission.
  Future<bool> hasAccessibilityPermission() async {
    try {
      return await _channel
              .invokeMethod<bool>('hasAccessibilityPermission') ??
          false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('hasAccessibilityPermission error: $e');
      return false;
    }
  }

  /// Opens the system accessibility settings so the user can enable this app.
  Future<void> openAccessibilitySettings() async {
    try {
      await _channel.invokeMethod<void>('openAccessibilitySettings');
    } on MissingPluginException {
      debugPrint('openAccessibilitySettings: channel not available');
    } catch (e) {
      debugPrint('openAccessibilitySettings error: $e');
    }
  }

  // ── Time Requests ─────────────────────────────────────────────────────────

  /// Submit a time extension request from the child to the parent
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
      await _db.collection('timeRequests').add({
        'childId': childId,
        'childName': childName,
        'parentUid': parentUid,
        'appName': appName,
        'packageName': packageName,
        'requestedMinutes': requestedMinutes,
        'childNote': childNote ?? '',
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      debugPrint('submitTimeRequest error: $e');
      return false;
    }
  }

  /// Watch a single time request document for status changes
  Stream<Map<String, dynamic>?> watchTimeRequest(String id) {
    return _db.collection('timeRequests').doc(id).snapshots().map(
          (snap) => snap.exists ? snap.data() : null,
        );
  }
}
