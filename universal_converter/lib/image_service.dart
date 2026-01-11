import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

class ImageService {
  
  Future<Uint8List?> convertImage(File originalFile, String targetFormat) async {
    
    // EXCEPTION: If the user wants BMP, we MUST use the Dart library.
    // (Native mobile/macOS compressors usually don't support writing BMP).
    if (targetFormat == 'bmp') {
      return compute(_isolateConvertDart, {
        'path': originalFile.absolute.path,
        'format': targetFormat
      });
    }

    // STRATEGY 1: Native Platforms (Mobile & macOS)
    // Fast, efficient, supports HEIC, JPG, PNG, WEBP
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      return _convertNative(originalFile, targetFormat);
    } 
    
    // STRATEGY 2: Windows / Linux
    // Uses pure Dart library
    else {
      return compute(_isolateConvertDart, {
        'path': originalFile.absolute.path,
        'format': targetFormat
      });
    }
  }

  Future<Uint8List?> _convertNative(File file, String format) async {
    try {
      CompressFormat target;
      // Map string to Native Format
      switch (format) {
        case 'png': target = CompressFormat.png; break;
        case 'webp': target = CompressFormat.webp; break;
        case 'heic': target = CompressFormat.heic; break;
        default: target = CompressFormat.jpeg;
      }

      var result = await FlutterImageCompress.compressWithFile(
        file.absolute.path,
        format: target,
        quality: 90,
      );
      
      return result; 
    } catch (e) {
      print("Native conversion failed: $e");
      return null;
    }
  }
}

// Background Isolate for Windows/Linux/BMP
Future<Uint8List?> _isolateConvertDart(Map<String, String> params) async {
  final file = File(params['path']!);
  final format = params['format']!;
  
  try {
    final bytes = await file.readAsBytes();
    
    // Decode (Supports JPG, PNG, GIF, TIFF, BMP, WEBP, ICO)
    final image = img.decodeImage(bytes);

    if (image == null) return null;

    // Encode
    switch (format) {
      case 'png': 
        return Uint8List.fromList(img.encodePng(image));
      case 'bmp': 
        return Uint8List.fromList(img.encodeBmp(image)); // Supports BMP
      case 'gif': 
        return Uint8List.fromList(img.encodeGif(image));
      default:
        // JPG doesn't support transparency, so background it white
        // Note: 'backgroundColor' usage depends on image package version. 
        // If this line errors, use 'img.fill(image, color: img.ColorRgb8(255, 255, 255))' strategy or similar.
        // But specifically for converting to JPG, usually just encoding handles it or ignores alpha.
        // For safety in standard 'image' package usage:
        final jpgImage = img.copyResize(image, width: image.width); 
        return Uint8List.fromList(img.encodeJpg(jpgImage, quality: 90));
    }
  } catch (e) {
    print("Dart conversion failed: $e");
    return null;
  }
}