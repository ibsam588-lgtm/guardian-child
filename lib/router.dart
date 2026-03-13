import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'services/pairing_service.dart';
import 'screens/splash_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/home_screen.dart';
import 'screens/sos_screen.dart';
import 'screens/time_request_screen.dart';
import 'screens/settings_screen.dart';

GoRouter buildRouter(BuildContext context) {
  final pairing = context.read<PairingService>();

  return GoRouter(
    initialLocation: '/splash',
    redirect: (context, state) {
      final atSplash = state.matchedLocation == '/splash';
      if (atSplash) return null; // always allow splash

      final isPaired = pairing.isPaired;
      final atPairing = state.matchedLocation == '/pair';

      if (!isPaired && !atPairing) return '/pair';
      if (isPaired && atPairing) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/pair',   builder: (_, __) => const PairingScreen()),
      GoRoute(path: '/home',   builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/sos',    builder: (_, __) => const SosScreen()),
      GoRoute(
        path: '/time-request',
        builder: (_, state) {
          final extra = state.extra as Map<String, dynamic>? ?? {};
          return TimeRequestScreen(
            appName: extra['appName'] ?? 'an app',
            packageName: extra['packageName'] ?? '',
            requestId: extra['requestId'],
          );
        },
      ),
      GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
    ],
  );
}
