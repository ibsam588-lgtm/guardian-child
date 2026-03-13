import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/pairing_service.dart';
import '../services/auth_service.dart';
import '../services/monitor_service.dart';
import '../theme/app_theme.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _scale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut),
    );
    _opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.5)),
    );
    _ctrl.forward();
    _navigate();
  }

  Future<void> _navigate() async {
    // Ensure anonymous auth
    final auth = context.read<AuthService>();
    if (!auth.isSignedIn) {
      await FirebaseAuth.instance.signInAnonymously();
    }

    await Future.delayed(const Duration(milliseconds: 1800));
    if (!mounted) return;

    final pairing = context.read<PairingService>();
    if (pairing.isPaired) {
      // Start background monitoring
      context.read<MonitorService>().start(pairing.childId!);
      context.go('/home');
    } else {
      context.go('/pair');
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      body: Center(
        child: FadeTransition(
          opacity: _opacity,
          child: ScaleTransition(
            scale: _scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: const Icon(Icons.shield_rounded, size: 60, color: Colors.white),
                ),
                const SizedBox(height: 20),
                const Text(
                  'GuardIan',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Stay safe. Stay connected.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 15),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
