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

  // ── Replace these values with your child app's google-services.json values ──
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'YOUR_CHILD_API_KEY',
    appId: 'YOUR_CHILD_APP_ID',
    messagingSenderId: '913378360413',
    projectId: 'guardian-e28d4',
    storageBucket: 'guardian-e28d4.firebasestorage.app',
  );
}
