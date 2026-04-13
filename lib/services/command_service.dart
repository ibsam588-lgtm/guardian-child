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

  /// Called when the parent sends an unpair command (e.g., after deleteChild()).
  /// The registered handler should stop MonitorService and call PairingService.unpair().
  VoidCallback? onUnpairRequested;

  /// Start listening for commands targeted at [childId].
  void start(String childId) {
    _subscription?.cancel();
    _docCommandsSubscription?.cancel();

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
    for (final change in snapshot.docChanges) {
      if (change.type != DocumentChangeType.added) continue;
      final data = change.doc.data();
      if (data == null) continue;
      final command = data['command'] as String? ?? '';
      if (command == 'unpair') {
        debugPrint('CommandService: received unpair from doc commands');
        onUnpairRequested?.call();
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
