import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

class ImageService {
  
  Future<Uint8List?> convertImage(File originalFile, String targetFormat) async {
    // STRATEGY 1: Native Platforms (Mobile & macOS)
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      return _convertNative(originalFile, targetFormat);
    } 
    
    // STRATEGY 2: Windows / Linux (Background Isolate)
    else {
      return compute(_isolateConvertDart, {
        'path': originalFile.absolute.path,
        'format': targetFormat
      });
    }
  }

  Future<Uint8List?> _convertNative(File file, String format) async {
    try {
      // This method returns Future<Uint8List?>, so we have the bytes immediately.
      var result = await FlutterImageCompress.compressWithFile(
        file.absolute.path,
        format: format == 'png' ? CompressFormat.png : CompressFormat.jpeg,
        quality: 90,
      );
      
      return result; // <--- FIX: Return the bytes directly (removed .readAsBytes)
    } catch (e) {
      print("Native conversion failed: $e");
      return null;
    }
  }
}

// Background Isolate for Windows/Linux
Future<Uint8List?> _isolateConvertDart(Map<String, String> params) async {
  final file = File(params['path']!);
  final format = params['format']!;
  
  try {
    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes);

    if (image == null) return null;

    if (format == 'png') {
      return Uint8List.fromList(img.encodePng(image));
    } else {
      // JPEGs can't have transparency, so we give it a white background
      final jpgImage = img.copyResize(image, width: image.width, backgroundColor: img.ColorRgb8(255, 255, 255));
      return Uint8List.fromList(img.encodeJpg(jpgImage, quality: 90));
    }
  } catch (e) {
    print("Dart conversion failed: $e");
    return null;
  }
}