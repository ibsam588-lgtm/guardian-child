import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/pairing_service.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';
  bool _locationGranted = false;
  bool _notificationGranted = false;
  bool _bgLocationGranted = false;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final loc = await Permission.locationWhenInUse.status;
    final notif = await Permission.notification.status;
    final bgLoc = await Permission.locationAlways.status;
    if (mounted) {
      setState(() {
        _locationGranted = loc.isGranted;
        _notificationGranted = notif.isGranted;
        _bgLocationGranted = bgLoc.isGranted;
      });
    }
  }

  Future<void> _openPermissions() async {
    await openAppSettings();
    // Re-check after returning from settings
    await Future.delayed(const Duration(milliseconds: 500));
    _checkPermissions();
  }

  @override
  Widget build(BuildContext context) {
    final pairing = context.read<PairingService>();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/home');
      },
      child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded),
          onPressed: () => context.go('/home'),
        ),
        title: const Text('Settings'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
        children: [
          // Profile card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [AppTheme.primary, const Color(0xFF9C8FFF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person_rounded, color: Colors.white, size: 30),
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pairing.childName ?? 'Child',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18),
                    ),
                    Text(
                      'Paired device',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),
          _SectionTitle('About'),
          _SettingsTile(
            icon: Icons.info_outline_rounded,
            title: 'Version',
            trailing: Text(_version, style: TextStyle(color: Colors.grey[600])),
          ),
          _SettingsTile(
            icon: Icons.shield_rounded,
            title: 'GuardIan Child',
            trailing: Text('v$_version', style: TextStyle(color: Colors.grey[600])),
          ),

          const SizedBox(height: 20),
          _SectionTitle('Permissions'),
          GestureDetector(
            onTap: _openPermissions,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8)],
              ),
              child: Column(children: [
                _PermissionRow(label: 'Location', granted: _locationGranted, icon: Icons.location_on_outlined),
                const Divider(height: 20),
                _PermissionRow(label: 'Background Location', granted: _bgLocationGranted, icon: Icons.my_location_outlined),
                const Divider(height: 20),
                _PermissionRow(label: 'Notifications', granted: _notificationGranted, icon: Icons.notifications_outlined),
                const SizedBox(height: 10),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Text('Tap to manage →',
                    style: TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w600)),
                ]),
              ]),
            ),
          ),

        ],
        ),
      ),
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  final String label;
  final bool granted;
  final IconData icon;
  const _PermissionRow({required this.label, required this.granted, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, color: AppTheme.primary, size: 20),
      const SizedBox(width: 12),
      Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: granted
            ? AppTheme.accent.withValues(alpha: 0.12)
            : Colors.red.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          granted ? 'Granted' : 'Denied',
          style: TextStyle(
            color: granted ? AppTheme.accent : Colors.red,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ),
    ]);
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey[500], letterSpacing: 1),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;
  const _SettingsTile({required this.icon, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8)],
      ),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.primary, size: 22),
          const SizedBox(width: 14),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
