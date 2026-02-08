import 'package:flutter/material.dart';
import 'home_screen.dart'; // This connects to the UI we created in Step 5

void main() {
  runApp(const ImageConverterApp());
}

class ImageConverterApp extends StatelessWidget {
  const ImageConverterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Universal Image Converter',
      debugShowCheckedModeBanner: false, // Removes the "Debug" sash
      theme: ThemeData(
        // A clean blue theme suitable for utility software
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      // The app starts here (The screen with Drag & Drop logic)
      home: const HomeScreen(),
    );
  }
