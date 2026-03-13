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

  // Lock to portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Transparent status bar
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

class _GuardianChildAppState extends State<GuardianChildApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<FcmService>().init(context);
    });
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
