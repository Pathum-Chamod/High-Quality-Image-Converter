import 'dart:io';
import 'package:flutter/foundation.dart'; // To check kIsWeb/Platform
import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart'; // For Drag & Drop
import 'package:file_picker/file_picker.dart'; // For Click & Pick
import 'package:path_provider/path_provider.dart'; // To find Downloads folder
import 'package:gal/gal.dart'; // For Mobile Gallery saving
import 'image_service.dart'; // The logic we wrote in Step 4

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImageService _imageService = ImageService();
  
  // State
  List<File> _selectedFiles = [];
  bool _isHovering = false; // For Drag & Drop visual feedback
  bool _isProcessing = false;
  double _progress = 0.0;
  String _status = "Ready";
  String _targetFormat = 'png'; // Default

  // --- ACTIONS ---

  // 1. Handle Drag & Drop (Desktop)
  void _onDragDone(DropDoneDetails details) {
    setState(() {
      // Filter to only allow files (ignore folders/text for now)
      _selectedFiles.addAll(details.files.map((e) => File(e.path)).toList());
    });
  }

  // 2. Handle Button Click (Mobile/Desktop)
  Future<void> _pickFiles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.image,
    );

    if (result != null) {
      setState(() {
        _selectedFiles.addAll(result.paths.map((path) => File(path!)).toList());
      });
    }
  }

  // 3. The Conversion Logic
  Future<void> _startConversion() async {
    if (_selectedFiles.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _progress = 0;
    });

    int successCount = 0;

    // Get the save directory based on platform
    String? savePath;
    if (Platform.isWindows || Platform.isMacOS) {
      final downloadDir = await getDownloadsDirectory();
      savePath = downloadDir?.path;
    }
    // Note: On Android/iOS we don't need a path, we save to Gallery directly via GAL.

    for (int i = 0; i < _selectedFiles.length; i++) {
      File file = _selectedFiles[i];
      
      try {
        // A. Update Status
        setState(() {
          _status = "Converting ${file.uri.pathSegments.last}...";
        });

        // B. Convert (Using the Service from Step 4)
        var bytes = await _imageService.convertImage(file, _targetFormat);

        if (bytes != null) {
          // C. Save Logic
          if (Platform.isWindows || Platform.isMacOS) {
            // Desktop: Write to disk
            final newFile = File('$savePath/converted_${DateTime.now().millisecondsSinceEpoch}.$_targetFormat');
            await newFile.writeAsBytes(bytes);
          } else {
            // Mobile: Save to Gallery
            // We need to write a temp file first for Gal to read it
            final tempDir = await getTemporaryDirectory();
            final tempFile = File('${tempDir.path}/temp.$_targetFormat');
            await tempFile.writeAsBytes(bytes);
            await Gal.putImage(tempFile.path);
          }
          successCount++;
        }
      } catch (e) {
        print("Error on file $i: $e");
      }

      // D. Update Progress
      setState(() {
        _progress = (i + 1) / _selectedFiles.length;
      });
    }

    // Finish
    setState(() {
      _isProcessing = false;
      _status = "Done! Saved $successCount images.";
      _selectedFiles.clear(); // Clear list after done
    });
  }

  // --- UI CONSTRUCTION ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Universal Converter")),
      body: Stack(
        children: [
          // The Drop Zone Area
          DropTarget(
            onDragDone: _onDragDone,
            onDragEntered: (_) => setState(() => _isHovering = true),
            onDragExited: (_) => setState(() => _isHovering = false),
            child: Container(
              color: _isHovering ? Colors.blue.withOpacity(0.2) : Colors.transparent,
              child: Column(
                children: [
                  // 1. Controls Area
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: _isProcessing ? null : _pickFiles,
                          icon: const Icon(Icons.add_photo_alternate),
                          label: const Text("Add Images"),
                        ),
                        const Spacer(),
                        DropdownButton<String>(
                          value: _targetFormat,
                          items: const [
                            DropdownMenuItem(value: 'png', child: Text("PNG")),
                            DropdownMenuItem(value: 'jpg', child: Text("JPG")),
                          ],
                          onChanged: (v) => setState(() => _targetFormat = v!),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          onPressed: _isProcessing || _selectedFiles.isEmpty 
                              ? null 
                              : _startConversion,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blueAccent,
                            foregroundColor: Colors.white
                          ),
                          child: Text(_isProcessing ? "Working..." : "Convert All"),
                        ),
                      ],
                    ),
                  ),

                  // 2. Progress Bar
                  if (_isProcessing) ...[
                    LinearProgressIndicator(value: _progress),
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(_status),
                    ),
                  ],

                  // 3. File List
                  Expanded(
                    child: _selectedFiles.isEmpty
                        ? Center(
                            child: Text(
                              Platform.isMacOS || Platform.isWindows 
                                  ? "Drag and drop images here" 
                                  : "No images selected",
                              style: TextStyle(color: Colors.grey[600], fontSize: 18),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _selectedFiles.length,
                            itemBuilder: (context, index) {
                              return ListTile(
                                leading: const Icon(Icons.image),
                                title: Text(_selectedFiles[index].uri.pathSegments.last),
                                trailing: IconButton(
                                  icon: const Icon(Icons.close, color: Colors.red),
                                  onPressed: () {
                                    setState(() {
                                      _selectedFiles.removeAt(index);
                                    });
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}