import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Listens for remote commands from the parent app via Firestore and
/// executes them on this device.
///
/// Two sources are monitored:
///   1. `child_commands` (top-level) — siren start/stop, sent via ChildService
///   2. `children/{childId}/commands` (subcollection) — unpair, sent via deleteChild()
class CommandService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  static const _channel = MethodChannel('com.guardian.child/monitor');

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _docCommandsSubscription;

  /// Timestamp (local) at which [start] was last called. Used to skip
  /// historical command docs that would otherwise be replayed on every
  /// app restart — Firestore delivers every existing document as a
  /// `DocumentChangeType.added` event on the first snapshot.
  DateTime? _startedAt;

  /// Called when the parent sends an unpair command (e.g., after deleteChild()).
  /// The registered handler should stop MonitorService and call PairingService.unpair().
  VoidCallback? onUnpairRequested;

  /// Start listening for commands targeted at [childId].
  void start(String childId) {
    _subscription?.cancel();
    _docCommandsSubscription?.cancel();
    _startedAt = DateTime.now();

    // Listen to top-level child_commands (siren, siren_stop)
    _subscription = _db
        .collection('child_commands')
        .where('childId', isEqualTo: childId)
        .where('executed', isEqualTo: false)
        .snapshots()
        .listen(_handleSnapshot, onError: (e) {
      debugPrint('CommandService error: $e');
    });

    // Listen to children/{childId}/commands subcollection (unpair from deleteChild)
    _docCommandsSubscription = _db
        .collection('children')
        .doc(childId)
        .collection('commands')
        .snapshots()
        .listen(_handleDocCommands, onError: (e) {
      debugPrint('CommandService doc commands error: $e');
    });
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _docCommandsSubscription?.cancel();
    _docCommandsSubscription = null;
  }

  void _handleSnapshot(QuerySnapshot<Map<String, dynamic>> snapshot) {
    for (final change in snapshot.docChanges) {
      if (change.type == DocumentChangeType.added ||
          change.type == DocumentChangeType.modified) {
        final data = change.doc.data();
        if (data == null) continue;
        final type = data['type'] as String? ?? '';
        _executeCommand(change.doc.id, type);
      }
    }
  }

  void _handleDocCommands(QuerySnapshot<Map<String, dynamic>> snapshot) {
    final started = _startedAt;
    for (final change in snapshot.docChanges) {
      if (change.type != DocumentChangeType.added) continue;
      final data = change.doc.data();
      if (data == null) continue;

      // Skip historical command docs: Firestore delivers every existing
      // document as an `added` event on the initial snapshot, which would
      // replay every siren / SOS / sync command the parent ever sent on
      // each app restart. Only honour commands written AFTER we started
      // listening (plus a small 30-second grace window for clock skew).
      final ts = data['timestamp'];
      if (ts is Timestamp && started != null) {
        if (ts.toDate().isBefore(started.subtract(const Duration(seconds: 30)))) {
          continue;
        }
      }

      // The parent app writes either {'command': 'unpair'} or
      // {'action': 'siren' | 'siren_stop' | 'unpair'} depending on the call site.
      // Support both field names so every command is honoured.
      final command = (data['command'] as String?) ?? (data['action'] as String?) ?? '';
      switch (command) {
        case 'siren':
          debugPrint('CommandService: siren command received');
          _playSiren();
          break;
        case 'siren_stop':
          debugPrint('CommandService: siren_stop command received');
          _stopSiren();
          break;
        case 'unpair':
          debugPrint('CommandService: received unpair from doc commands');
          onUnpairRequested?.call();
          break;
      }
    }
  }

  Future<void> _executeCommand(String docId, String type) async {
    try {
      switch (type) {
        case 'siren':
          await _playSiren();
          break;
        case 'siren_stop':
          await _stopSiren();
          break;
        case 'unpair':
          debugPrint('CommandService: received unpair command');
          onUnpairRequested?.call();
          break;
        default:
          debugPrint('CommandService: unknown command type $type');
      }

      // Mark the command as executed so it is not re-processed.
      await _db.collection('child_commands').doc(docId).set({
        'executed': true,
        'executedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('CommandService: failed to execute $type – $e');
    }
  }

  /// Triggers the device siren via the native MonitorService.
  Future<void> _playSiren() async {
    try {
      await _channel.invokeMethod<void>('playSiren');
    } on MissingPluginException {
      debugPrint('CommandService: playSiren not available on this platform');
    } catch (e) {
      debugPrint('CommandService: siren error $e');
    }
  }

  /// Stops the device siren via the native MonitorService.
  Future<void> _stopSiren() async {
    try {
      await _channel.invokeMethod<void>('stopSiren');
    } on MissingPluginException {
      debugPrint('CommandService: stopSiren not available on this platform');
    } catch (e) {
      debugPrint('CommandService: stopSiren error $e');
    }
  }
}
