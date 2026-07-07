import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Google Cast (CAF) is initialized lazily by the first cast-button action
  // (startDiscovery / connectAndCast), never here: eager init was awaited
  // before the first frame — a GMS binder round-trip on every cold start — and
  // it's pure waste on a TV, which is a receiver and never casts out.
  // CastService.supported additionally gates the whole stack off on a TV.
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
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: const HomeScreen(),
    );
  }
}
