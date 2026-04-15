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
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _childDocSubscription;

  /// First doc snapshot is ignored — if the parent already deleted the
  /// child and we're only now subscribing, we still treat that as an
  /// unpair. But when we first start listening against an EXISTING doc
  /// (the normal case) we don't want a spurious unpair on startup.
  bool _childDocSeen = false;

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
    _childDocSubscription?.cancel();
    _startedAt = DateTime.now();
    _childDocSeen = false;

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

    // Listen to the main children/{childId} doc itself. When the parent
    // removes the child from their account, they delete this document
    // (and the commands subcollection seconds later) — so doc deletion
    // is the most reliable "you are unpaired" signal, especially if the
    // child device was offline at the moment the unpair command was
    // written and it got cleaned up before the snapshot arrived.
    _childDocSubscription = _db
        .collection('children')
        .doc(childId)
        .snapshots()
        .listen(_handleChildDocSnapshot, onError: (e) {
      debugPrint('CommandService child doc error: $e');
    });
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _docCommandsSubscription?.cancel();
    _docCommandsSubscription = null;
    _childDocSubscription?.cancel();
    _childDocSubscription = null;
  }

  void _handleChildDocSnapshot(
      DocumentSnapshot<Map<String, dynamic>> snap) {
    if (!_childDocSeen) {
      _childDocSeen = true;
      // If the VERY FIRST snapshot shows the doc doesn't exist, the parent
      // has already removed this child (or the record was never created).
      // Treat that as an unpair too.
      if (!snap.exists) {
        debugPrint('CommandService: child doc missing on first snapshot — unpairing');
        onUnpairRequested?.call();
      }
      return;
    }
    if (!snap.exists) {
      debugPrint('CommandService: child doc deleted — unpairing');
      onUnpairRequested?.call();
    }
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

      // The parent app writes either {'command': 'unpair'} or
      // {'action': 'siren' | 'siren_stop' | 'unpair'} depending on the call site.
      // Support both field names so every command is honoured.
      final command = (data['command'] as String?) ?? (data['action'] as String?) ?? '';

      // Skip historical command docs: Firestore delivers every existing
      // document as an `added` event on the initial snapshot, which would
      // replay every siren / SOS command the parent ever sent on each app
      // restart. `unpair` is exempt — it's idempotent and we want it to
      // fire even if the parent removed the child while this device was
      // offline (in which case the unpair doc is "historical" by the time
      // the child reconnects).
      if (command != 'unpair') {
        final ts = data['timestamp'];
        if (ts is Timestamp && started != null) {
          if (ts.toDate().isBefore(started.subtract(const Duration(seconds: 30)))) {
            continue;
          }
        }
      }

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
