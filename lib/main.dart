import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'theme/app_theme.dart';
import 'services/auth_service.dart';
import 'services/pairing_service.dart';
import 'services/monitor_service.dart';
import 'services/fcm_service.dart';
import 'router.dart';

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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final pairing = context.read<PairingService>();
    final monitor = context.read<MonitorService>();
    final childId = pairing.childId;

    switch (state) {
      case AppLifecycleState.resumed:
        // App came back to foreground — resume heartbeat if paired
        if (childId != null) monitor.start(childId);
        break;
      case AppLifecycleState.detached:
        // App is truly being closed — mark offline
        if (childId != null) {
          unawaited(context.read<AuthService>().setOffline(childId));
        }
        break;
      default:
        // paused / hidden — foreground service keeps running, no action needed
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'GuardIan Child',
      theme: AppTheme.childTheme(),
      routerConfig: buildRouter(context),
      debugShowCheckedModeBanner: false,
    );
  }
}
