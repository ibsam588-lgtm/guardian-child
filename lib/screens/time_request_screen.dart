import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/pairing_service.dart';
import '../services/monitor_service.dart';
import '../theme/app_theme.dart';

class TimeRequestScreen extends StatefulWidget {
  final String appName;
  final String packageName;
  final String? requestId; // if already submitted, watch this
  /// "blocked" — asking parent for permission to use a blocked app.
  /// "limit_reached" (default) — asking parent for more time on an
  /// app whose daily limit has been reached.
  final String? reason;

  const TimeRequestScreen({
    super.key,
    required this.appName,
    required this.packageName,
    this.requestId,
    this.reason,
  });

  bool get _isPermission => reason == 'blocked';

  @override
  State<TimeRequestScreen> createState() => _TimeRequestScreenState();
}

class _TimeRequestScreenState extends State<TimeRequestScreen> {
  int _selectedMinutes = 30;
  final TextEditingController _noteCtrl = TextEditingController();
  bool _sending = false;
  bool _sent = false;
  String _status = 'pending';
  /// ID of the timeRequests doc backing this request. Captured on
  /// submit or carried in from widget.requestId when we re-enter the
  /// screen to watch an already-sent request. Used by the Cancel
  /// Request button to target the right doc.
  String? _requestId;
  StreamSubscription? _watchSub;

  final List<_TimeOption> _options = const [
    _TimeOption(minutes: 15, emoji: '⚡', label: '15 min'),
    _TimeOption(minutes: 30, emoji: '⏱', label: '30 min'),
    _TimeOption(minutes: 60, emoji: '🕐', label: '1 hour'),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.requestId != null) {
      _sent = true;
      _requestId = widget.requestId;
      _watchRequest(widget.requestId!);
    }
  }

  @override
  void dispose() {
    _watchSub?.cancel();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendRequest() async {
    setState(() { _sending = true; });
    final pairing = context.read<PairingService>();
    final monitor = context.read<MonitorService>();

    final docId = await monitor.submitTimeRequest(
      childId: pairing.childId!,
      childName: pairing.childName ?? 'Your child',
      parentUid: pairing.parentUid!,
      appName: widget.appName,
      packageName: widget.packageName,
      requestedMinutes: _selectedMinutes,
      childNote: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
    );

    if (!mounted) return;
    setState(() { _sending = false; });

    if (docId != null) {
      setState(() {
        _sent = true;
        _requestId = docId;
      });
      // Watch for parent's response now that we have the doc ID.
      _watchRequest(docId);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not send request. Please try again.')),
      );
    }
  }

  void _watchRequest(String id) {
    final monitor = context.read<MonitorService>();
    _watchSub = monitor.watchTimeRequest(id).listen(
      (data) {
        if (data != null && mounted) {
          setState(() => _status = data['status'] ?? 'pending');
        }
      },
      onError: (e) => debugPrint('watchTimeRequest error: $e'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded),
          onPressed: () => context.go('/home'),
        ),
        title: Text(widget._isPermission ? 'Request Unblock' : 'Request More Time'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _sent ? _waitingView() : _requestForm(),
        ),
      ),
    );
  }

  Widget _requestForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // App name display
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.apps_rounded, color: AppTheme.primary),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget._isPermission
                        ? 'Requesting unblock for'
                        : 'Requesting more time for',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  Text(
                    widget.appName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF2D2D2D)),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),

        const Text('How much time do you need?',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF2D2D2D)),
        ),
        const SizedBox(height: 14),
        Row(
          children: _options.map((opt) {
            final selected = _selectedMinutes == opt.minutes;
            return Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _selectedMinutes = opt.minutes),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: selected ? AppTheme.primary : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: selected ? AppTheme.primary : const Color(0xFFE0E0E0),
                      width: 2,
                    ),
                    boxShadow: selected ? [
                      BoxShadow(color: AppTheme.primary.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4)),
                    ] : [],
                  ),
                  child: Column(
                    children: [
                      Text(opt.emoji, style: const TextStyle(fontSize: 22)),
                      const SizedBox(height: 6),
                      Text(
                        opt.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: selected ? Colors.white : const Color(0xFF2D2D2D),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 28),

        const Text('Add a note (optional)',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF2D2D2D)),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _noteCtrl,
          maxLines: 3,
          maxLength: 120,
          decoration: InputDecoration(
            hintText: 'e.g. "Almost done with my homework, please?"',
            hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: AppTheme.primary, width: 2),
            ),
          ),
        ),
        const SizedBox(height: 32),

        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _sending ? null : _sendRequest,
            child: _sending
                ? const SizedBox(width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : Text(widget._isPermission
                    ? 'Send Unblock Request'
                    : 'Send $_selectedMinutes min Request'),
          ),
        ),
      ],
    );
  }

  Widget _waitingView() {
    Color statusColor;
    IconData statusIcon;
    String statusTitle;
    String statusMsg;

    final isPerm = widget._isPermission;
    switch (_status) {
      case 'approved':
        statusColor = AppTheme.accent;
        statusIcon = Icons.check_circle_rounded;
        statusTitle = isPerm ? 'Unblocked!' : 'Request Approved!';
        statusMsg = isPerm
            ? 'Your parent unblocked ${widget.appName} for $_selectedMinutes min.'
            : 'Your parent said yes. Enjoy your extra time!';
        break;
      case 'denied':
        statusColor = AppTheme.secondary;
        statusIcon = Icons.cancel_rounded;
        statusTitle = 'Not This Time';
        statusMsg = 'Your parent said no. Try asking again later.';
        break;
      default:
        statusColor = AppTheme.warning;
        statusIcon = Icons.hourglass_top_rounded;
        statusTitle = isPerm
            ? 'Unblock Request Sent'
            : 'Request Sent';
        statusMsg = 'Your parent will see your request and respond soon.';
    }

    return Column(
      children: [
        const SizedBox(height: 40),
        Icon(statusIcon, color: statusColor, size: 80),
        const SizedBox(height: 20),
        Text(statusTitle,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Color(0xFF2D2D2D)),
        ),
        const SizedBox(height: 12),
        Text(statusMsg,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[600], fontSize: 15, height: 1.5),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('App', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
              Text(widget.appName,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF2D2D2D)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Time asked', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
              Text('$_selectedMinutes min',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF2D2D2D)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 40),
        if (_status == 'pending')
          OutlinedButton.icon(
            onPressed: _cancelRequest,
            icon: const Icon(Icons.close, color: AppTheme.secondary),
            label: const Text('Cancel Request',
                style: TextStyle(
                    color: AppTheme.secondary, fontWeight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppTheme.secondary, width: 1.5),
              padding: const EdgeInsets.symmetric(
                  horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        if (_status != 'pending')
          ElevatedButton(
            onPressed: () => context.go('/home'),
            child: const Text('Back to Home'),
          ),
      ],
    );
  }

  /// Called when the child taps Cancel Request while waiting. Deletes
  /// the timeRequests doc entirely so the parent's home screen no
  /// longer shows it as pending. Safer than a status update because
  /// the parent's listener filters by status and we don't want a
  /// "cancelled" tombstone cluttering their Requests tab.
  Future<void> _cancelRequest() async {
    final requestId = _requestId;
    if (requestId == null || requestId.isEmpty) {
      // Can't cancel what we don't have a reference to.
      if (mounted) context.go('/home');
      return;
    }
    try {
      await FirebaseFirestore.instance
          .collection('timeRequests')
          .doc(requestId)
          .delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Request cancelled')));
        context.go('/home');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not cancel: $e'),
            backgroundColor: AppTheme.secondary));
      }
    }
  }
}

class _TimeOption {
  final int minutes;
  final String emoji;
  final String label;
  const _TimeOption({required this.minutes, required this.emoji, required this.label});
}
