import 'package:flutter/material.dart';
import 'home_screen.dart';

void main() {
  runApp(const ImageConverterApp());
}

class ImageConverterApp extends StatelessWidget {
  const ImageConverterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Universal Converter',
      debugShowCheckedModeBanner: false,

      // --- LIGHT THEME ---
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C63FF),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F5FA),
        fontFamily: 'SF Pro Display',
      ),

      // --- DARK THEME ---
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C63FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0F0F1A),
        fontFamily: 'SF Pro Display',
      ),

      // Follows system setting (dark/light)
      themeMode: ThemeMode.system,

      home: const HomeScreen(),
    );
  }
}