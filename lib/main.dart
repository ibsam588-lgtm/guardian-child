import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'theme/app_theme.dart';
import 'services/auth_service.dart';
import 'services/pairing_service.dart';
import 'services/monitor_service.dart';
import 'services/fcm_service.dart';
import 'screens/splash_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/home_screen.dart';
import 'screens/sos_screen.dart';
import 'screens/time_request_screen.dart';
import 'screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));

  final prefs = await SharedPreferences.getInstance();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProvider(create: (_) => PairingService(prefs)),
        ChangeNotifierProvider(create: (_) => MonitorService(prefs)),
        Provider(create: (_) => FcmService()),
      ],
      child: const GuardianChildApp(),
    ),
  );
}

class GuardianChildApp extends StatefulWidget {
  const GuardianChildApp({super.key});
  @override
  State<GuardianChildApp> createState() => _GuardianChildAppState();
}

class _GuardianChildAppState extends State<GuardianChildApp>
    with WidgetsBindingObserver {

  // ── CRITICAL FIX: Cache the router so it's only built ONCE ──────────────
  // Building a new GoRouter on every rebuild resets navigation state.
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Build router once, using the PairingService instance
    final pairing = context.read<PairingService>();
    _router = _buildRouter(pairing);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<FcmService>().init(context);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final pairing = context.read<PairingService>();
    final monitor = context.read<MonitorService>();
    final childId = pairing.childId;

    switch (state) {
      case AppLifecycleState.resumed:
        if (childId != null) monitor.start(childId);
        break;
      case AppLifecycleState.detached:
        if (childId != null) {
          unawaited(context.read<AuthService>().setOffline(childId));
        }
        break;
      default:
        break;
    }
  }

  GoRouter _buildRouter(PairingService pairing) {
    return GoRouter(
      initialLocation: '/splash',
      // Refresh router when pairing state changes so redirects re-evaluate
      refreshListenable: pairing,
      redirect: (context, state) {
        final atSplash = state.matchedLocation == '/splash';
        if (atSplash) return null;

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

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'GuardIan Child',
      theme: AppTheme.childTheme(),
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
