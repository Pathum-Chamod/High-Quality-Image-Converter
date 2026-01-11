import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

class VideoService {
  
  /// Converts video using the BUNDLED FFmpeg binary.
  Future<bool> convertVideo(String inputPath, String outputPath) async {
    try {
      // 1. Get the path to our internal FFmpeg
      String? ffmpegPath = await _getFFmpegPath();
      
      if (ffmpegPath == null) {
        print("Error: Could not extract FFmpeg binary.");
        return false;
      }

      print("Using FFmpeg at: $ffmpegPath");

      // 2. Run the command
      final result = await Process.run(
        ffmpegPath, 
        ['-i', inputPath, '-y', outputPath], 
        runInShell: true
      );

      if (result.exitCode == 0) {
        return true;
      } else {
        print("FFmpeg Conversion Error: ${result.stderr}");
        return false;
      }
    } catch (e) {
      print("System Error: $e");
      return false;
    }
  }

  /// Extracts the binary from assets to a usable location
  Future<String?> _getFFmpegPath() async {
    try {
      final dir = await getApplicationSupportDirectory();
      String binaryName;
      String assetPath;

      if (Platform.isWindows) {
        binaryName = "ffmpeg.exe";
        assetPath = "assets/bin/ffmpeg.exe";
      } else if (Platform.isMacOS) {
        binaryName = "ffmpeg";
        assetPath = "assets/bin/ffmpeg_mac";
      } else {
        return null; // Linux/Mobile logic would go here
      }

      final file = File("${dir.path}/$binaryName");

      // Optimization: Only copy if it doesn't exist yet
      if (!await file.exists()) {
        final byteData = await rootBundle.load(assetPath);
        final bytes = byteData.buffer.asUint8List();
        await file.writeAsBytes(bytes);
        
        // CRITICAL for Mac: Make it executable
        if (Platform.isMacOS) {
          await Process.run('chmod', ['+x', file.path]);
        }
      }

      return file.path;
    } catch (e) {
      print("Error extracting binary: $e");
      return null;
    }
  }
}