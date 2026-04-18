import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/pairing_service.dart';
import '../theme/app_theme.dart';

class SosScreen extends StatefulWidget {
  const SosScreen({super.key});

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  Timer? _autoResetTimer;
  bool _sending = false;
  bool _sent = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _autoResetTimer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendSOS() async {
    setState(() { _sending = true; _error = null; });

    final pairing = context.read<PairingService>();
    final childId = pairing.childId;
    final parentUid = pairing.parentUid;

    if (childId == null || parentUid == null) {
      if (!mounted) return;
      setState(() { _sending = false; _error = 'Not paired yet.'; });
      return;
    }

    // Best-effort location lookup — never block the SOS alert on it.
    double? lat, lng;
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 5),
          ),
        ).timeout(const Duration(seconds: 6));
        lat = pos.latitude;
        lng = pos.longitude;
      }
    } catch (_) {
      // Location failure is non-fatal — send the SOS without coordinates.
    }

    try {
      // Write SOS alert to Firestore (primary channel for parent notification).
      await FirebaseFirestore.instance.collection('alerts').add({
        'childId': childId,
        'parentUid': parentUid,
        'type': 'sos',
        'title': 'SOS Alert',
        'subtitle': '${pairing.childName ?? 'Your child'} needs help!',
        'lat': lat,
        'lng': lng,
        'timestamp': FieldValue.serverTimestamp(),
        'isRead': false,
      });

      // Also update child doc so parent sees the SOS banner on dashboard.
      await FirebaseFirestore.instance.collection('children').doc(childId).set({
        'sosActive': true,
        'sosAt': FieldValue.serverTimestamp(),
        if (lat != null) 'lastLat': lat,
        if (lng != null) 'lastLng': lng,
      }, SetOptions(merge: true));

      // Also write an SOS command so any legacy listener picks it up.
      unawaited(FirebaseFirestore.instance
          .collection('children')
          .doc(childId)
          .collection('commands')
          .add({
        'action': 'sos',
        'parentUid': parentUid,
        'timestamp': FieldValue.serverTimestamp(),
      }));

      // Note: we intentionally do NOT trigger the local siren on the
      // child's own phone here. A child pressing SOS wants discreet help,
      // not to announce themselves to whoever is near them. The siren is
      // a parent-initiated command (`siren` in child_commands) — the
      // parent can trigger it explicitly from the emergency screen if
      // they decide audible escalation is appropriate.

      if (!mounted) return;
      setState(() { _sending = false; _sent = true; });

      // Immediately call the first emergency contact on file.
      unawaited(_callFirstEmergencyContact(childId, parentUid));

      // Auto-cancel SOS active flag after 30 seconds (parent will have seen it).
      // Capture childId into a local so the callback never dereferences a
      // freshly-unpaired (null) childId via `pairing.childId`.
      final lockedChildId = childId;
      _autoResetTimer = Timer(const Duration(seconds: 30), () {
        if (lockedChildId.isEmpty) return;
        FirebaseFirestore.instance
            .collection('children')
            .doc(lockedChildId)
            .set({'sosActive': false}, SetOptions(merge: true))
            .catchError((e) {
          debugPrint('SOS auto-cancel error: $e');
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Could not send SOS. Check your internet and try again.';
      });
    }
  }

  Future<void> _callFirstEmergencyContact(
      String childId, String parentUid) async {
    try {
      // Contacts are stored under the parent's document:
      //   users/{parentUid}/emergency_contacts  (written by guardian-app,
      //   mirrored to children/{childId}/emergency_contacts for child access).
      // Query the child-side mirror first; fall back to parent collection.
      QuerySnapshot<Map<String, dynamic>> snapshot = await FirebaseFirestore
          .instance
          .collection('children')
          .doc(childId)
          .collection('emergency_contacts')
          .orderBy('order')
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        // Fall back to parent collection (e.g. contacts added before the
        // dual-write was in place).
        snapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(parentUid)
            .collection('emergency_contacts')
            .orderBy('order')
            .limit(1)
            .get();
      }

      if (snapshot.docs.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'No emergency contact on file. Ask your parent to add one.'),
          ),
        );
        return;
      }

      final data = snapshot.docs.first.data();
      final phone =
          ((data['phone'] ?? data['phoneNumber'] ?? '') as String).trim();

      if (phone.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Emergency contact has no phone number on file.')),
        );
        return;
      }

      final uri = Uri(scheme: 'tel', path: phone);
      // LaunchMode.externalApplication ensures the dialler app opens even
      // if the tel: scheme would otherwise be handled in-app.
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Emergency call error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && context.mounted) context.go('/home');
      },
      child: Scaffold(
        backgroundColor: _sent ? const Color(0xFFF0FBF7) : const Color(0xFFFFF5F5),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_rounded),
            onPressed: () => context.go('/home'),
          ),
          title: const Text('SOS'),
        ),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: _sent ? _sentView() : _sosView(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sosView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'Need Help?',
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: Color(0xFF2D2D2D)),
        ),
        const SizedBox(height: 10),
        Text(
          'Press the button to alert your parent\nwith your location instantly.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[600], fontSize: 15, height: 1.5),
        ),
        const SizedBox(height: 56),

        // Pulsing SOS button
        AnimatedBuilder(
          animation: _pulseCtrl,
          builder: (_, __) {
            return Stack(
              alignment: Alignment.center,
              children: [
                // Outer pulse rings
                ...List.generate(3, (i) {
                  return Container(
                    width: 120.0 + (i * 30) + (_pulseCtrl.value * 20),
                    height: 120.0 + (i * 30) + (_pulseCtrl.value * 20),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppTheme.secondary.withValues(alpha: 0.15 - (i * 0.04)),
                        width: 2,
                      ),
                    ),
                  );
                }),
                GestureDetector(
                  onTap: _sending ? null : _sendSOS,
                  child: Container(
                    width: 120, height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.secondary,
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.secondary.withValues(alpha: 0.5),
                          blurRadius: 24 + (_pulseCtrl.value * 12),
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: _sending
                        ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 3)
                        : const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.sos_rounded, color: Colors.white, size: 40),
                              Text('HELP', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 2)),
                            ],
                          ),
                  ),
                ),
              ],
            );
          },
        ),

        if (_error != null) ...[
          const SizedBox(height: 24),
          Text(_error!, style: TextStyle(color: AppTheme.secondary, fontSize: 14)),
        ],

        const SizedBox(height: 48),
        Text(
          'Your parent will be notified immediately\nwith your current location.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[500], fontSize: 13),
        ),
      ],
    );
  }

  Widget _sentView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 100, height: 100,
          decoration: BoxDecoration(
            color: AppTheme.accent.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.check_circle_rounded, color: AppTheme.accent, size: 60),
        ),
        const SizedBox(height: 24),
        const Text(
          'Alert Sent!',
          style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Color(0xFF2D2D2D)),
        ),
        const SizedBox(height: 10),
        Text(
          'Your parent has been notified.\nStay where you are if it\'s safe to do so.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[600], fontSize: 15, height: 1.5),
        ),
        const SizedBox(height: 48),
        ElevatedButton(
          onPressed: () async {
            // Stop the local siren when the child acknowledges they're safe.
            try {
              await const MethodChannel('com.guardian.child/monitor')
                  .invokeMethod('stopSiren');
            } catch (_) {/* ignore */}
            if (context.mounted) context.go('/home');
          },
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accent),
          child: const Text("I'm OK — Go Back"),
        ),
      ],
    );
  }
}
