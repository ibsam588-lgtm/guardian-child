import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/monitor_service.dart';

const _monitorChannel = MethodChannel('com.guardian.child/monitor');

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  bool _requesting = false;
  bool _hasUsageAccess = false;
  bool _callSmsGranted = false;
  bool _accessibilityGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _requestAll();
    });
  }

  Future<bool> _checkUsageAccess() async {
    try {
      return await _monitorChannel
              .invokeMethod<bool>('hasUsageStatsPermission') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _requestAll() async {
    setState(() => _requesting = true);

    await [
      Permission.location,
      Permission.notification,
      Permission.phone,
      Permission.sms,
    ].request();

    await _checkCallSms();
    await _checkUsageAccess();
    await _checkAccessibility();

    if (mounted) setState(() => _requesting = false);
  }

  Future<void> _checkCallSms() async {
    final phone = await Permission.phone.isGranted;
    final sms = await Permission.sms.isGranted;
    setState(() => _callSmsGranted = phone && sms);
  }

  Future<void> _requestCallSms() async {
    await [Permission.phone, Permission.sms].request();
    _checkCallSms();
  }

  Future<void> _checkAccessibility() async {
    final monitor = context.read<MonitorService>();
    final granted = await monitor.hasAccessibilityPermission();
    setState(() => _accessibilityGranted = granted);
  }

  Future<void> _requestAccessibility() async {
    final monitor = context.read<MonitorService>();
    await monitor.openAccessibilitySettings();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Permissions Required'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Guardian Child Monitoring',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'To monitor your child effectively, Guardian Child requires several permissions.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 32),
              _PermissionItem(
                icon: Icons.location_on_outlined,
                title: 'Location',
                description: 'Real-time location tracking',
                isGranted: false,
                onRequest: () async {
                  setState(() => _requesting = true);
                  await Permission.location.request();
                  setState(() => _requesting = false);
                },
              ),
              const SizedBox(height: 16),
              _PermissionItem(
                icon: Icons.notifications_outlined,
                title: 'Notifications',
                description: 'Send alerts and notifications',
                isGranted: false,
                onRequest: () async {
                  setState(() => _requesting = true);
                  await Permission.notification.request();
                  setState(() => _requesting = false);
                },
              ),
              const SizedBox(height: 16),
              _PermissionItem(
                icon: Icons.bar_chart_outlined,
                title: 'Usage Stats',
                description: 'Track app usage and screen time',
                isGranted: _hasUsageAccess,
                onRequest: () async {
                  setState(() => _requesting = true);
                  await _monitorChannel
                      .invokeMethod('openUsageStatsSettings');
                  await Future.delayed(const Duration(seconds: 2));
                  final granted = await _checkUsageAccess();
                  setState(() {
                    _hasUsageAccess = granted;
                    _requesting = false;
                  });
                },
              ),
              const SizedBox(height: 16),
              _PermissionItem(
                icon: Icons.battery_std_outlined,
                title: 'Battery Optimization',
                description:
                    'Prevent battery optimization interference',
                isGranted: false,
                onRequest: () async {
                  setState(() => _requesting = true);
                  await _monitorChannel
                      .invokeMethod('openBatteryOptimization');
                  setState(() => _requesting = false);
                },
              ),
              const SizedBox(height: 16),
              _PermissionItem(
                icon: Icons.phone_outlined,
                title: 'Call & SMS Monitoring',
                description:
                    'Read call logs and text messages for parental monitoring',
                isGranted: _callSmsGranted,
                onRequest: _requestCallSms,
              ),
              const SizedBox(height: 16),
              _PermissionItem(
                icon: Icons.language_outlined,
                title: 'Browser Monitoring',
                description:
                    'Track browser activity using accessibility service',
                isGranted: _accessibilityGranted,
                onRequest: _requestAccessibility,
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      _requesting ? null : () => context.go('/pairing'),
                  child: const Text('Continue to Pairing'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool isGranted;
  final VoidCallback onRequest;

  const _PermissionItem({
    required this.icon,
    required this.title,
    required this.description,
    required this.isGranted,
    required this.onRequest,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(
          color: isGranted
              ? Theme.of(context)
                  .colorScheme
                  .primary
                  .withAlpha((0.3 * 255).toInt())
              : Theme.of(context)
                  .colorScheme
                  .outline
                  .withAlpha((0.2 * 255).toInt()),
        ),
        borderRadius: BorderRadius.circular(12),
        color: isGranted
            ? Theme.of(context)
                .colorScheme
                .primary
                .withAlpha((0.1 * 255).toInt())
            : Colors.transparent,
      ),
      child: Row(
        children: [
          Icon(icon,
              color: Theme.of(context).colorScheme.primary, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7),
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (isGranted)
            Icon(Icons.check_circle,
                color: Theme.of(context).colorScheme.primary)
          else
            FilledButton(
              onPressed: onRequest,
              child: const Text('Allow'),
            ),
        ],
      ),
    );
  }
}

