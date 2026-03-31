import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Listens for remote commands from the parent app via the
/// `child_commands` Firestore collection and executes them on this device.
class CommandService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  static const _channel = MethodChannel('com.guardian.child/monitor');

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;
  String? _childId;

  /// Start listening for commands targeted at [childId].
  void start(String childId) {
    _childId = childId;
    _subscription?.cancel();

    _subscription = _db
        .collection('child_commands')
        .where('childId', isEqualTo: childId)
        .where('executed', isEqualTo: false)
        .snapshots()
        .listen(_handleSnapshot, onError: (e) {
      debugPrint('CommandService error: $e');
    });
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
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

  Future<void> _executeCommand(String docId, String type) async {
    try {
      switch (type) {
        case 'siren':
          await _playSiren();
          break;
        case 'siren_stop':
          await _stopSiren();
          break;
        case 'listen_start':
          // Ambient listening – placeholder for future audio streaming
          debugPrint('CommandService: listen_start received');
          break;
        case 'listen_stop':
          debugPrint('CommandService: listen_stop received');
          break;
        default:
          debugPrint('CommandService: unknown command type $type');
      }

      // Mark the command as executed so it is not re-processed.
      await _db.collection('child_commands').doc(docId).update({
        'executed': true,
        'executedAt': FieldValue.serverTimestamp(),
      });
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
