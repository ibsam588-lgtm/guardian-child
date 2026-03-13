import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError('DefaultFirebaseOptions not supported for this platform.');
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCSgmed57xmEAJm2zKbyIGc5LvX_zYg6Hg',
    appId: '1:913378360413:android:c36202494651161270e1b4',
    messagingSenderId: '913378360413',
    projectId: 'guardian-e28d4',
    storageBucket: 'guardian-e28d4.firebasestorage.app',
  );
}
