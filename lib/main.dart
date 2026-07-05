import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'screens/home_screen.dart';
import 'services/cast_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Best-effort Google Cast init (Android only); never blocks app startup.
  await CastService.instance.ensureInitialized();
  runApp(const UrlVideoPlayerApp());
}

class UrlVideoPlayerApp extends StatelessWidget {
  const UrlVideoPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Url Video Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const HomeScreen(),
    );
  }
}
