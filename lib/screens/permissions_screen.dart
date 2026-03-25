import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/pairing_service.dart';
import '../services/monitor_service.dart';
import '../theme/app_theme.dart';

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});
  @override State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    // Auto-trigger the OS permission dialogs as soon as the screen appears.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _requestAll();
    });
  }

  Future<void> _requestAll() async {
    setState(() => _requesting = true);

    // Request in sequence — each dialog appears one at a time
    await Permission.locationWhenInUse.request();
    await Permission.notification.request();
    // Background location only after foreground is granted
    final loc = await Permission.locationWhenInUse.status;
    if (loc.isGranted) {
      await Permission.locationAlways.request();
    }

    if (!mounted) return;

    // Start monitor NOW — after permissions are granted so the
    // foreground service won't crash with a SecurityException
    final pairing = context.read<PairingService>();
    if (pairing.childId != null) {
      context.read<MonitorService>().start(pairing.childId!);
    }

    context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              Container(
                width: 72, height: 72,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.primary, AppTheme.secondary]),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.shield_rounded,
                    color: Colors.white, size: 40),
              ),
              const SizedBox(height: 28),
              const Text('Allow Permissions',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800,
                    color: Color(0xFF2D2D2D))),
              const SizedBox(height: 10),
              Text('GuardIan needs a few permissions to keep you safe.',
                style: TextStyle(fontSize: 15, color: Colors.grey[600],
                    height: 1.5)),
              const SizedBox(height: 36),
              _PermRow(icon: Icons.location_on_rounded,
                  color: const Color(0xFF3B82F6),
                  title: 'Location',
                  subtitle: "So your parent can see you're safe"),
              _PermRow(icon: Icons.notifications_rounded,
                  color: const Color(0xFFF59E0B),
                  title: 'Notifications',
                  subtitle: 'For alerts and check-ins from your parent'),
              _PermRow(icon: Icons.my_location_rounded,
                  color: const Color(0xFF10B981),
                  title: 'Background Location',
                  subtitle: 'Needed even when the app is closed'),
              const Spacer(),
              SizedBox(
                width: double.infinity, height: 54,
                child: ElevatedButton(
                  onPressed: _requesting ? null : _requestAll,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16))),
                  child: _requesting
                    ? const SizedBox(width: 22, height: 22,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5))
                    : const Text('Allow Permissions',
                        style: TextStyle(fontSize: 16,
                            fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () {
                    // Skip — but still start monitor (without location it
                    // will just report battery / online status only)
                    final pairing = context.read<PairingService>();
                    if (pairing.childId != null) {
                      context.read<MonitorService>().start(pairing.childId!);
                    }
                    context.go('/home');
                  },
                  child: Text('Skip for now',
                    style: TextStyle(color: Colors.grey[500],
                        fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  const _PermRow({required this.icon, required this.color,
      required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(children: [
        Container(
          width: 50, height: 50,
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, color: color, size: 26),
        ),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700,
              fontSize: 15, color: Color(0xFF2D2D2D))),
          Text(subtitle, style: TextStyle(fontSize: 12,
              color: Colors.grey[600])),
        ])),
      ]),
    );
  }
}
