import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart'; // For checking platform
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img; // Pure Dart library for Desktop

class ImageService {
  
  /// Main entry point: Converts file at [path] to [targetFormat]
  /// Returns the bytes of the new image.
  Future<Uint8List?> convertImage(File originalFile, String targetFormat) async {
    
    // STRATEGY 1: Mobile (iOS/Android)
    // We use the native OS compressor because it's super fast and supports HEIC.
    if (Platform.isAndroid || Platform.isIOS) {
      return _convertMobile(originalFile, targetFormat);
    } 
    
    // STRATEGY 2: Desktop (Windows/Mac/Linux)
    // We use the 'image' library (Pure Dart) because it has no native dependencies.
    else {
      return _convertDesktop(originalFile, targetFormat);
    }
  }

  // --- Mobile Logic ---
  Future<Uint8List?> _convertMobile(File file, String format) async {
    var result = await FlutterImageCompress.compressWithFile(
      file.absolute.path,
      format: format == 'png' ? CompressFormat.png : CompressFormat.jpeg,
      quality: 90,
    );
    return result;
  }

  // --- Desktop Logic ---
  // Note: This runs on the UI thread by default. 
  // For production, we must move this to an Isolate (Step 5).
  Future<Uint8List?> _convertDesktop(File file, String format) async {
    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes); // Decodes JPG, PNG, GIF, WebP, TIFF

    if (image == null) return null;

    if (format == 'png') {
      return Uint8List.fromList(img.encodePng(image));
    } else {
      return Uint8List.fromList(img.encodeJpg(image, quality: 90));
    }
  }
}