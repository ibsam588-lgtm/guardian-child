import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:battery_plus/battery_plus.dart';
import '../services/pairing_service.dart';
import '../services/monitor_service.dart';
import '../theme/app_theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _batteryLevel = 0;

  @override
  void initState() {
    super.initState();
    _loadBattery();
  }

  Future<void> _loadBattery() async {
    final battery = Battery();
    final level = await battery.batteryLevel;
    if (mounted) setState(() => _batteryLevel = level);
  }

  @override
  Widget build(BuildContext context) {
    final pairing = context.read<PairingService>();
    final monitor = context.watch<MonitorService>();
    final childName = pairing.childName ?? 'Hey!';
    final childId = pairing.childId;

    if (childId == null) {
      // Shouldn't happen, but guard against it
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/pair');
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Exit GuardIan?'),
            content: const Text('Do you want to close the app?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true),  child: const Text('Exit')),
            ],
          ),
        );
        if (shouldExit == true) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // ── Header ──────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _greeting(),
                            style: TextStyle(color: Colors.grey[600], fontSize: 14),
                          ),
                          Text(
                            childName,
                            style: const TextStyle(
                              fontSize: 26, fontWeight: FontWeight.w800, color: Color(0xFF2D2D2D),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // SOS button
                    GestureDetector(
                      onTap: () => context.go('/sos'),
                      child: Container(
                        width: 50, height: 50,
                        decoration: BoxDecoration(
                          color: AppTheme.secondary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.secondary.withValues(alpha: 0.4),
                              blurRadius: 12, offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.sos_rounded, color: Colors.white, size: 26),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Status card ──────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: _StatusCard(
                  batteryLevel: _batteryLevel,
                  location: monitor.lastLocation,
                ),
              ),
            ),

            // ── App Limits ───────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
                child: Row(
                  children: [
                    const Text(
                      'App Time',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF2D2D2D)),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Set by parent',
                        style: TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  if (monitor.appLimits.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                      child: _EmptyLimits(),
                    );
                  }
                  final limit = monitor.appLimits[i];
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                    child: _AppLimitCard(
                      limit: limit,
                      childId: childId,
                      childName: childName,
                      parentUid: pairing.parentUid ?? '',
                    ),
                  );
                },
                childCount: monitor.appLimits.isEmpty ? 1 : monitor.appLimits.length,
              ),
            ),

            // ── Time Requests ────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                child: const Text(
                  'My Requests',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF2D2D2D)),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: _RecentRequests(childId: childId),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),

      // ── Bottom nav ────────────────────────────────────────────────────
      bottomNavigationBar: Container(
        padding: EdgeInsets.only(
          top: 12,
          bottom: 12 + MediaQuery.of(context).padding.bottom,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 16)],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _NavBtn(icon: Icons.home_rounded, label: 'Home', selected: true, onTap: () {}),
            _NavBtn(icon: Icons.sos_rounded, label: 'SOS', onTap: () => context.go('/sos')),
            _NavBtn(icon: Icons.settings_rounded, label: 'Settings', onTap: () => context.go('/settings')),
          ],
        ),
      ),
      ),
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning,';
    if (h < 17) return 'Good afternoon,';
    return 'Good evening,';
  }
}

// ── Status card ────────────────────────────────────────────────────────────────
class _StatusCard extends StatelessWidget {
  final int batteryLevel;
  final String location;
  const _StatusCard({required this.batteryLevel, required this.location});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppTheme.primary, const Color(0xFF9C8FFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.35),
            blurRadius: 20, offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              _StatusItem(
                icon: Icons.location_on_rounded,
                label: 'Location',
                value: location.isEmpty || location == 'Unknown'
                    ? 'Waiting...'
                    : location.split(',').first.trim(),
              ),
              const SizedBox(width: 16),
              _StatusItem(
                icon: Icons.battery_std_rounded,
                label: 'Battery',
                value: '$batteryLevel%',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(color: Color(0xFF43D6A0), shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Your parent can see you\'re safe',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatusItem({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Colors.white70, size: 18),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
            Text(value,
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ── App limit card ─────────────────────────────────────────────────────────────
class _AppLimitCard extends StatelessWidget {
  final AppLimitInfo limit;
  final String childId;
  final String childName;
  final String parentUid;
  const _AppLimitCard({
    required this.limit, required this.childId,
    required this.childName, required this.parentUid,
  });

  @override
  Widget build(BuildContext context) {
    final isBlocked = limit.isBlocked;
    final color = isBlocked ? AppTheme.secondary : AppTheme.primary;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10)],
      ),
      child: Row(
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              isBlocked ? Icons.block_rounded : Icons.apps_rounded,
              color: color, size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(limit.appName,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF2D2D2D)),
                ),
                Text(
                  isBlocked ? 'Blocked by parent' : '${limit.dailyLimitMinutes} min / day',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          if (!isBlocked && limit.allowTimeRequests)
            TextButton(
              onPressed: () {
                context.go('/time-request', extra: {
                  'appName': limit.appName,
                  'packageName': limit.packageName,
                });
              },
              style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
              child: const Text('Ask', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

class _EmptyLimits extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, color: AppTheme.accent, size: 28),
          const SizedBox(width: 14),
          const Text('No app limits set yet', style: TextStyle(fontSize: 14, color: Colors.grey)),
        ],
      ),
    );
  }
}

// ── Recent requests ────────────────────────────────────────────────────────────
class _RecentRequests extends StatelessWidget {
  final String childId;
  const _RecentRequests({required this.childId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('timeRequests')
          .where('childId', isEqualTo: childId)
          .limit(10)
          .snapshots(),
      builder: (ctx, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(18),
              ),
              child: const Text('Could not load requests', style: TextStyle(color: Colors.grey)),
            ),
          );
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: LinearProgressIndicator(),
          );
        }
        // Sort client-side to avoid composite index requirement
        final docs = snap.data!.docs.toList()
          ..sort((a, b) {
            final tsA = ((a.data() as Map<String, dynamic>)['createdAt'] as Timestamp?)
                ?.millisecondsSinceEpoch ?? 0;
            final tsB = ((b.data() as Map<String, dynamic>)['createdAt'] as Timestamp?)
                ?.millisecondsSinceEpoch ?? 0;
            return tsB.compareTo(tsA);
          });
        final topDocs = docs.take(5).toList();
        if (topDocs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(18),
              ),
              child: const Text('No requests yet', style: TextStyle(color: Colors.grey)),
            ),
          );
        }
        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          itemCount: topDocs.length,
          itemBuilder: (_, i) {
            final d = topDocs[i].data() as Map<String, dynamic>;
            final status = d['status'] ?? 'pending';
            return _RequestTile(appName: d['appName'] ?? '', status: status, minutes: d['requestedMinutes'] ?? 15);
          },
        );
      },
    );
  }
}

class _RequestTile extends StatelessWidget {
  final String appName;
  final String status;
  final int minutes;
  const _RequestTile({required this.appName, required this.status, required this.minutes});

  @override
  Widget build(BuildContext context) {
    Color statusColor;
    IconData statusIcon;
    String statusLabel;
    switch (status) {
      case 'approved':
        statusColor = AppTheme.accent; statusIcon = Icons.check_circle_rounded; statusLabel = 'Approved';
        break;
      case 'denied':
        statusColor = AppTheme.secondary; statusIcon = Icons.cancel_rounded; statusLabel = 'Denied';
        break;
      default:
        statusColor = AppTheme.warning; statusIcon = Icons.hourglass_top_rounded; statusLabel = 'Pending';
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8)],
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$appName — $minutes min',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFF2D2D2D)),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8),
            ),
            child: Text(statusLabel, style: TextStyle(fontSize: 11, color: statusColor, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ── Nav button ─────────────────────────────────────────────────────────────────
class _NavBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  const _NavBtn({required this.icon, required this.label, required this.onTap, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.primary : Colors.grey;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
