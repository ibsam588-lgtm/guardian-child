import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/pairing_service.dart';
import '../services/monitor_service.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
  }

  Future<void> _unpair() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Unpair device?', style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text(
          'This will disconnect from your parent\'s GuardIan account. You\'ll need a new code to reconnect.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.secondary),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      context.read<MonitorService>().stop();
      await context.read<PairingService>().unpair();
      if (mounted) context.go('/pair');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pairing = context.read<PairingService>();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded),
          onPressed: () => context.go('/home'),
        ),
        title: const Text('Settings'),
      ),
      body: ListView(
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
                    color: Colors.white.withOpacity(0.2),
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
                      style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13),
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
          _SectionTitle('Privacy'),
          _SettingsTile(
            icon: Icons.location_on_outlined,
            title: 'Location Sharing',
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('On', style: TextStyle(color: AppTheme.accent, fontWeight: FontWeight.w600, fontSize: 12)),
            ),
          ),
          _SettingsTile(
            icon: Icons.battery_std_outlined,
            title: 'Battery Status',
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('On', style: TextStyle(color: AppTheme.accent, fontWeight: FontWeight.w600, fontSize: 12)),
            ),
          ),

          const SizedBox(height: 20),
          _SectionTitle('Danger Zone'),
          GestureDetector(
            onTap: _unpair,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.secondary.withOpacity(0.06),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.secondary.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.link_off_rounded, color: AppTheme.secondary, size: 22),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Unpair this device',
                          style: TextStyle(color: AppTheme.secondary, fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                        Text('Disconnect from parent account',
                          style: TextStyle(color: AppTheme.secondary.withOpacity(0.7), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: AppTheme.secondary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
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
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 8)],
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
