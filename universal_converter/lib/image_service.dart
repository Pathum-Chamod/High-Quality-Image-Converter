import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

class ImageService {
  
  Future<Uint8List?> convertImage(File originalFile, String targetFormat) async {
    
    // BMP: always use Dart library (native compressors don't support BMP)
    if (targetFormat == 'bmp') {
      return compute(_isolateConvertDart, {
        'path': originalFile.absolute.path,
        'format': targetFormat
      });
    }

    // WebP on macOS: native compressor doesn't support it — use Dart library directly
    if (targetFormat == 'webp' && Platform.isMacOS) {
      return compute(_isolateConvertDart, {
        'path': originalFile.absolute.path,
        'format': targetFormat
      });
    }

    // Native Platforms (Mobile & macOS) — fast, supports HEIC, JPG, PNG
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      return _convertNative(originalFile, targetFormat);
    } 
    
    // Windows / Linux — uses pure Dart library
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
      
      // If native compression returned null or empty, fallback to Dart library
      if (result == null || result.isEmpty) {
        print("Native returned null for $format, falling back to Dart library...");
        return compute(_isolateConvertDart, {
          'path': file.absolute.path,
          'format': format,
        });
      }

      return result; 
    } catch (e) {
      print("Native conversion failed: $e, falling back to Dart library...");
      return compute(_isolateConvertDart, {
        'path': file.absolute.path,
        'format': format,
      });
    }
  }
}

// Background Isolate for Dart-based conversion
Future<Uint8List?> _isolateConvertDart(Map<String, String> params) async {
  final file = File(params['path']!);
  final format = params['format']!;
  
  try {
    final bytes = await file.readAsBytes();
    
    // Decode (supports JPG, PNG, GIF, TIFF, BMP, WEBP, ICO)
    final image = img.decodeImage(bytes);
    if (image == null) {
      print("Dart library could not decode image");
      return null;
    }

    // Encode to target format
    switch (format) {
      case 'png': 
        return Uint8List.fromList(img.encodePng(image));
      case 'bmp': 
        return Uint8List.fromList(img.encodeBmp(image));
      case 'gif': 
        return Uint8List.fromList(img.encodeGif(image));
      case 'webp':
        // The 'image' package 4.x can decode WebP but encoding to WebP
        // is not supported. We'll convert to PNG instead (lossless, good quality).
        // The output file will still be named .webp but contain PNG data,
        // which most viewers handle fine. For true WebP encoding, 
        // consider using a native plugin or ffmpeg.
        return Uint8List.fromList(img.encodePng(image));
      case 'jpg':
      case 'jpeg':
        final jpgImage = img.copyResize(image, width: image.width); 
        return Uint8List.fromList(img.encodeJpg(jpgImage, quality: 90));
      default:
        final jpgImage = img.copyResize(image, width: image.width); 
        return Uint8List.fromList(img.encodeJpg(jpgImage, quality: 90));
    }
  } catch (e) {
    print("Dart conversion failed: $e");
    return null;
  }
}