import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import '../services/pairing_service.dart';
import '../theme/app_theme.dart';

class SosScreen extends StatefulWidget {
  const SosScreen({super.key});

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
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
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendSOS() async {
    setState(() { _sending = true; _error = null; });

    final pairing = context.read<PairingService>();
    final childId = pairing.childId;
    final parentUid = pairing.parentUid;

    if (childId == null || parentUid == null) {
      setState(() { _sending = false; _error = 'Not paired yet.'; });
      return;
    }

    try {
      double? lat, lng;

      // Try getting location
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        ).timeout(const Duration(seconds: 10));
        lat = pos.latitude;
        lng = pos.longitude;
      }

      // Write SOS alert to Firestore
      await FirebaseFirestore.instance.collection('alerts').add({
        'childId': childId,
        'parentUid': parentUid,
        'type': 'sos',
        'title': '🚨 SOS Alert',
        'subtitle': '${pairing.childName ?? 'Your child'} needs help!',
        'lat': lat,
        'lng': lng,
        'timestamp': FieldValue.serverTimestamp(),
        'isRead': false,
      });

      // Also update child doc so parent sees it on dashboard
      await FirebaseFirestore.instance.collection('children').doc(childId).update({
        'sosActive': true,
        'sosAt': FieldValue.serverTimestamp(),
      });

      setState(() { _sending = false; _sent = true; });

      // Auto-cancel SOS after 30 seconds (parent will have seen it)
      Timer(const Duration(seconds: 30), () {
        unawaited(FirebaseFirestore.instance.collection('children').doc(childId).update({
          'sosActive': false,
        }));
      });
    } catch (e) {
      setState(() { _sending = false; _error = 'Could not send SOS. Try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
          onPressed: () => context.go('/home'),
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accent),
          child: const Text("I'm OK — Go Back"),
        ),
      ],
    );
  }
}
