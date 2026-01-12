import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

class VideoService {
  
  Future<bool> convertVideo(String inputPath, String outputPath) async {
    try {
      // 1. Extract the FFmpeg binary from assets to a real file
      final ffmpegPath = await _extractFFmpeg();
      
      if (ffmpegPath == null) {
        print("Error: Could not find FFmpeg binary.");
        return false;
      }

      print("Using FFmpeg at: $ffmpegPath");

      // 2. Run the conversion command
      final result = await Process.run(
        ffmpegPath, 
        ['-i', inputPath, '-y', outputPath], 
        runInShell: true
      );

      if (result.exitCode == 0) {
        return true;
      } else {
        print("FFmpeg Error: ${result.stderr}");
        return false;
      }
    } catch (e) {
      print("System Error: $e");
      return false;
    }
  }

  /// Copies the asset to a temporary folder and makes it executable
  Future<String?> _extractFFmpeg() async {
    try {
      final dir = await getApplicationSupportDirectory();
      String assetPath;
      String binaryName;

      if (Platform.isMacOS) {
        binaryName = "ffmpeg";
        assetPath = "assets/bin/ffmpeg_mac";
      } else if (Platform.isWindows) {
        binaryName = "ffmpeg.exe";
        assetPath = "assets/bin/ffmpeg.exe";
      } else {
        return null;
      }

      final file = File("${dir.path}/$binaryName");

      // Only copy if it doesn't exist yet to save time
      if (!await file.exists()) {
        final byteData = await rootBundle.load(assetPath);
        final bytes = byteData.buffer.asUint8List();
        await file.writeAsBytes(bytes);

        // IMPORTANT: Make it executable on Mac
        if (Platform.isMacOS) {
          await Process.run('chmod', ['+x', file.path]);
        }
      }
      return file.path;
    } catch (e) {
      print("Extraction Error: $e");
      return null;
    }
  }
}