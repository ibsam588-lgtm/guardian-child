import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'theme/app_theme.dart';
import 'services/auth_service.dart';
import 'services/pairing_service.dart';
import 'services/monitor_service.dart';
import 'services/fcm_service.dart';
import 'services/command_service.dart';
import 'screens/splash_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/home_screen.dart';
import 'screens/sos_screen.dart';
import 'screens/time_request_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/permissions_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // ── Crashlytics ──────────────────────────────────────────────────────────
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

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

  // Cache the router so it's NEVER rebuilt — rebuilding resets navigation
  GoRouter? _router;
  final _commandService = CommandService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<FcmService>().init(context);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _commandService.stop();
    _router?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final pairing = context.read<PairingService>();
    final monitor = context.read<MonitorService>();
    final childId = pairing.childId;

    switch (state) {
      case AppLifecycleState.resumed:
        if (childId != null) {
          monitor.start(childId);
          _commandService.start(childId);
        }
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
      refreshListenable: pairing,
      redirect: (context, state) {
        final atSplash = state.matchedLocation == '/splash';
        if (atSplash) return null;

        final isPaired = pairing.isPaired;
        final atPairing = state.matchedLocation == '/pair';
        final atPermissions = state.matchedLocation == '/permissions';

        if (!isPaired && !atPairing) return '/pair';
        if (isPaired && atPairing) return '/home';
        if (isPaired && atPermissions) return null; // allow permissions screen
        return null;
      },
      routes: [
        GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
        GoRoute(path: '/pair',   builder: (_, __) => const PairingScreen()),
        GoRoute(path: '/permissions', builder: (_, __) => const PermissionsScreen()),
        GoRoute(path: '/home',   builder: (_, __) => const HomeScreen()),
        GoRoute(path: '/sos',    builder: (_, __) => const SosScreen()),
        GoRoute(
          path: '/time-request',
          builder: (_, state) {
            final extra = state.extra as Map<String, dynamic>? ?? {};
            return TimeRequestScreen(
              appName: extra['appName'] as String? ?? 'an app',
              packageName: extra['packageName'] as String? ?? '',
              requestId: extra['requestId'] as String?,
            );
          },
        ),
        GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pairing = context.read<PairingService>();
    // Build router once and cache it — never rebuild
    _router ??= _buildRouter(pairing);

    return MaterialApp.router(
      title: 'GuardIan Child',
      theme: AppTheme.childTheme(),
      routerConfig: _router!,
      debugShowCheckedModeBanner: false,
    );
  }
}
