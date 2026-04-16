import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';

/// Full list of alerts sent to this child device by the parent.
///
/// Uses PopScope so the system back gesture/button always returns to /home
/// rather than exiting the app (which happened when this route replaced the
/// stack via context.go instead of context.push).
class AlertsScreen extends StatelessWidget {
  final String childId;
  const AlertsScreen({super.key, required this.childId});

  @override
  Widget build(BuildContext context) {
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
          title: const Text('Alerts'),
          actions: [
            TextButton(
              onPressed: () => _clearAll(context),
              child: Text(
                'Clear All',
                style: TextStyle(color: AppTheme.secondary, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        body: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('children')
              .doc(childId)
              .collection('alerts')
              .orderBy('createdAt', descending: true)
              .limit(50)
              .snapshots(),
          builder: (ctx, snap) {
            if (snap.hasError) {
              return const Center(child: Text('Could not load alerts'));
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final docs = snap.data!.docs
                .where((d) => (d.data() as Map<String, dynamic>)['isRead'] != true)
                .toList();

            if (docs.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.notifications_none_rounded,
                        size: 64, color: Colors.grey[300]),
                    const SizedBox(height: 16),
                    Text(
                      'No alerts',
                      style: TextStyle(color: Colors.grey[500], fontSize: 16),
                    ),
                  ],
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: docs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final data = docs[i].data() as Map<String, dynamic>;
                return _AlertTile(
                  docId: docs[i].id,
                  childId: childId,
                  data: data,
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _clearAll(BuildContext context) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('children')
          .doc(childId)
          .collection('alerts')
          .where('isRead', isNotEqualTo: true)
          .get();

      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snap.docs) {
        batch.update(doc.reference, {'isRead': true});
      }
      await batch.commit();
    } catch (e) {
      debugPrint('AlertsScreen: clear all error $e');
    }
  }
}

class _AlertTile extends StatelessWidget {
  final String docId;
  final String childId;
  final Map<String, dynamic> data;

  const _AlertTile({
    required this.docId,
    required this.childId,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    final message = data['message'] as String? ?? 'Alert from parent';
    final type = data['type'] as String? ?? 'info';
    final ts = (data['createdAt'] as Timestamp?)?.toDate();

    IconData icon;
    Color color;
    switch (type) {
      case 'warning':
        icon = Icons.warning_amber_rounded;
        color = AppTheme.warning;
        break;
      case 'blocked':
        icon = Icons.block_rounded;
        color = AppTheme.secondary;
        break;
      case 'sos':
        icon = Icons.sos_rounded;
        color = AppTheme.secondary;
        break;
      default:
        icon = Icons.info_outline_rounded;
        color = AppTheme.primary;
    }

    return Dismissible(
      key: Key(docId),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.check_circle_outline, color: Colors.red),
      ),
      onDismissed: (_) {
        FirebaseFirestore.instance
            .collection('children')
            .doc(childId)
            .collection('alerts')
            .doc(docId)
            .update({'isRead': true}).catchError(
                (e) => debugPrint('AlertTile dismiss error: $e'));
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: Color(0xFF2D2D2D))),
                  if (ts != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _formatTime(ts),
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
