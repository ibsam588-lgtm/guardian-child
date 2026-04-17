import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

const _monitorChannel = MethodChannel('com.guardian.child/monitor');

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  bool _requesting = false;
  bool _locationGranted = false;
  bool _notificationGranted = false;
  bool _hasUsageAccess = false;
  bool _callSmsGranted = false;
  bool _batteryOptimized = false;
  bool _accessibilityGranted = false;
  bool _micGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _requestAll();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check permissions when user returns from system settings
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionStates();
    }
  }

  Future<void> _refreshPermissionStates() async {
    final loc = await Permission.location.isGranted;
    final notif = await Permission.notification.isGranted;
    final phone = await Permission.phone.isGranted;
    final sms = await Permission.sms.isGranted;
    final mic = await Permission.microphone.isGranted;
    final usage = await _checkUsageAccess();
    final battery = await _checkBatteryOptimization();
    final accessibility = await _checkAccessibility();

    if (mounted) {
      setState(() {
        _locationGranted = loc;
        _notificationGranted = notif;
        _callSmsGranted = phone && sms;
        _micGranted = mic;
        _hasUsageAccess = usage;
        _batteryOptimized = battery;
        _accessibilityGranted = accessibility;
      });
    }
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

  Future<bool> _checkAccessibility() async {
    try {
      return await _monitorChannel
              .invokeMethod<bool>('hasAccessibilityPermission') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _checkBatteryOptimization() async {
    try {
      return await _monitorChannel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _requestAll() async {
    setState(() => _requesting = true);

    // Request standard permissions
    await [
      Permission.location,
      Permission.notification,
      Permission.phone,
      Permission.sms,
      Permission.microphone,
    ].request();

    // After foreground location is granted, request background location
    final locGranted = await Permission.location.isGranted;
    if (locGranted) {
      final bgStatus = await Permission.locationAlways.status;
      if (!bgStatus.isGranted) {
        await Permission.locationAlways.request();
      }
    }

    await _refreshPermissionStates();

    if (mounted) setState(() => _requesting = false);
  }

  Future<void> _requestLocation() async {
    setState(() => _requesting = true);
    final status = await Permission.location.request();
    if (status.isGranted) {
      // Now request background location
      await Permission.locationAlways.request();
    }
    final loc = await Permission.location.isGranted;
    setState(() {
      _locationGranted = loc;
      _requesting = false;
    });
  }

  Future<void> _requestNotification() async {
    setState(() => _requesting = true);
    await Permission.notification.request();
    final granted = await Permission.notification.isGranted;
    setState(() {
      _notificationGranted = granted;
      _requesting = false;
    });
  }

  Future<void> _requestCallSms() async {
    setState(() => _requesting = true);
    await [Permission.phone, Permission.sms].request();
    final phone = await Permission.phone.isGranted;
    final sms = await Permission.sms.isGranted;
    setState(() {
      _callSmsGranted = phone && sms;
      _requesting = false;
    });
  }

  Future<void> _requestMicrophone() async {
    setState(() => _requesting = true);
    await Permission.microphone.request();
    final granted = await Permission.microphone.isGranted;
    setState(() {
      _micGranted = granted;
      _requesting = false;
    });
  }

  void _continue() {
    // Start the monitor service now that permissions are granted
    context.go('/home');
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
      body: SafeArea(
        // System nav bar / gesture area was clipping the bottom buttons on
        // some phones (especially those with thick gesture pills). Wrap in
        // SafeArea and add explicit MediaQuery-driven bottom inset so the
        // last button is always reachable regardless of device.
        top: false,
        bottom: true,
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 24.0,
            right: 24.0,
            top: 24.0,
            bottom: 24.0 + MediaQuery.of(context).viewPadding.bottom,
          ),
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
                description: 'Real-time location tracking (always)',
                isGranted: _locationGranted,
                onRequest: _requestLocation,
              ),
              const SizedBox(height: 16),
              _PermissionItem(
                icon: Icons.notifications_outlined,
                title: 'Notifications',
                description: 'Send alerts and notifications',
                isGranted: _notificationGranted,
                onRequest: _requestNotification,
              ),
              const SizedBox(height: 16),
              _PermissionItem(
                icon: Icons.bar_chart_outlined,
                title: 'Usage Stats',
                description: 'Track app usage and screen time',
                isGranted: _hasUsageAccess,
                onRequest: () async {
                  setState(() => _requesting = true);
                  try {
                    await _monitorChannel
                        .invokeMethod('openUsageAccessSettings');
                  } catch (_) {
                    // Gracefully handle MissingPluginException
                  }
                  // State will refresh via didChangeAppLifecycleState when user returns
                  setState(() => _requesting = false);
                },
              ),
              const SizedBox(height: 16),
              _PermissionItem(
                icon: Icons.battery_std_outlined,
                title: 'Battery Optimization',
                description:
                    'Prevent battery optimization interference',
                isGranted: _batteryOptimized,
                onRequest: () async {
                  setState(() => _requesting = true);
                  try {
                    await _monitorChannel
                        .invokeMethod('openBatteryOptimization');
                  } catch (_) {
                    // Gracefully handle MissingPluginException
                  }
                  // Give the system dialog time to resolve, then check
                  await Future.delayed(const Duration(seconds: 1));
                  final granted = await _checkBatteryOptimization();
                  setState(() {
                    _batteryOptimized = granted;
                    _requesting = false;
                  });
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
                icon: Icons.mic_outlined,
                title: 'Microphone',
                description:
                    'Always-on microphone access for remote audio monitoring',
                isGranted: _micGranted,
                onRequest: _requestMicrophone,
              ),
              const SizedBox(height: 16),
              _PermissionItem(
                icon: Icons.accessibility_new_outlined,
                title: 'Accessibility Service',
                description:
                    'Monitor browser activity and track visited websites',
                isGranted: _accessibilityGranted,
                onRequest: () async {
                  setState(() => _requesting = true);
                  try {
                    await _monitorChannel
                        .invokeMethod('openAccessibilitySettings');
                  } catch (_) {
                    // Gracefully handle MissingPluginException
                  }
                  // State will refresh via didChangeAppLifecycleState when user returns
                  setState(() => _requesting = false);
                },
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _requesting ? null : _continue,
                  child: const Text('Continue'),
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
