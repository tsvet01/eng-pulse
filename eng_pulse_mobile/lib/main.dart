import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';
import 'services/cache_service.dart';
import 'services/connectivity_service.dart';
import 'services/notification_service.dart';
import 'services/user_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  // Note: This will fail until you run `flutterfire configure`
  // Comment out Firebase initialization if you haven't set up Firebase yet
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // Initialize notifications after Firebase
    await NotificationService.init();
    // Subscribe to daily briefings topic
    await NotificationService.subscribeToTopic('daily_briefings');
  } catch (e) {
    debugPrint('Firebase initialization failed: $e');
    debugPrint('Run `flutterfire configure` to set up Firebase');
  }

  // Initialize other services
  await CacheService.init();
  await ConnectivityService.init();
  await UserService.init();

  // Set system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
    ),
  );

  runApp(const EngPulseApp());
}

class EngPulseApp extends StatelessWidget {
  const EngPulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Eng Pulse',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: const SplashScreen(),
    );
  }
}
