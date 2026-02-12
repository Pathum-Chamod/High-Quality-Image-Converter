import 'dart:io';
import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'image_service.dart';
import 'video_service.dart'; // Import the new service

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImageService _imageService = ImageService();
  final VideoService _videoService = VideoService();
  
  // MODE: true = Video, false = Image
  bool _isVideoMode = false;

  List<File> _selectedFiles = [];
  bool _isHovering = false;
  bool _isProcessing = false;
  double _progress = 0.0;
  String _status = "Ready";
  
  // Formats
  String _targetImageFormat = 'png'; 
  String _targetVideoFormat = 'mp4';

  // --- ACTIONS ---

  void _onDragDone(DropDoneDetails details) {
    setState(() {
      final validFiles = details.files
          .map((e) => File(e.path))
          .where((f) => _isVideoMode ? _isVideo(f.path) : _isImage(f.path))
          .toList();
      _selectedFiles.addAll(validFiles);
    });
  }

  Future<void> _pickFiles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom, 
      allowedExtensions: _isVideoMode 
        ? ['mp4', 'mov', 'avi', 'mkv', 'flv', 'webm', 'wmv', 'gif']
        : ['jpg', 'jpeg', 'png', 'webp', 'heic', 'bmp', 'tiff'],
    );
    
    if (result != null) {
      setState(() {
        _selectedFiles.addAll(result.paths.map((path) => File(path!)).toList());
      });
    }
  }

  bool _isImage(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ['jpg', 'jpeg', 'png', 'webp', 'heic', 'bmp', 'tiff'].contains(ext);
  }

  bool _isVideo(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ['mp4', 'mov', 'avi', 'mkv', 'flv', 'webm', 'wmv', 'gif'].contains(ext);
  }

  void _toggleMode(int index) {
    setState(() {
      _isVideoMode = index == 1;
      _selectedFiles.clear(); // Clear files when switching modes
      _status = "Switched to ${_isVideoMode ? 'Video' : 'Image'} mode";
    });
  }

  Future<void> _startConversion() async {
    if (_selectedFiles.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _progress = 0;
    });

    int successCount = 0;
    String? savePath;
    
    if (Platform.isWindows || Platform.isMacOS) {
      final downloadDir = await getDownloadsDirectory();
      savePath = downloadDir?.path;
    }

    for (int i = 0; i < _selectedFiles.length; i++) {
      File file = _selectedFiles[i];
      setState(() => _status = "Converting ${i + 1}/${_selectedFiles.length}...");

      try {
        bool success = false;

        // --- VIDEO LOGIC ---
        if (_isVideoMode) {
          // Determine output path first
          String newPath;
          final name = file.uri.pathSegments.last.split('.').first;
          
          if (Platform.isWindows || Platform.isMacOS) {
            newPath = '$savePath/${name}_converted.$_targetVideoFormat';
          } else {
            final tempDir = await getTemporaryDirectory();
            newPath = '${tempDir.path}/$name.$_targetVideoFormat';
          }

          // Run FFmpeg
          success = await _videoService.convertVideo(file.path, newPath);

          // Save to Gallery on Mobile
          if (success && (Platform.isAndroid || Platform.isIOS)) {
            await Gal.putVideo(newPath);
            File(newPath).delete(); // Cleanup temp
          }
        } 
        
        // --- IMAGE LOGIC ---
        else {
          var bytes = await _imageService.convertImage(file, _targetImageFormat);
          if (bytes != null) {
            if (Platform.isWindows || Platform.isMacOS) {
              final name = file.uri.pathSegments.last.split('.').first;
              final newFile = File('$savePath/${name}_converted.$_targetImageFormat');
              await newFile.writeAsBytes(bytes);
            } else {
              final tempDir = await getTemporaryDirectory();
              final tempFile = File('${tempDir.path}/temp.$_targetImageFormat');
              await tempFile.writeAsBytes(bytes);
              await Gal.putImage(tempFile.path);
            }
            success = true;
          }
        }

        if (success) successCount++;

      } catch (e) {
        print("Error: $e");
      }

      setState(() => _progress = (i + 1) / _selectedFiles.length);
    }

    setState(() {
      _isProcessing = false;
      _status = "Done! Saved $successCount files.";
      _selectedFiles.clear(); 
    });
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Processed $successCount files successfully."),
        backgroundColor: successCount > 0 ? Colors.green : Colors.red,
      ));
    }
  }

  // --- UI ---

  @override
  Widget build(BuildContext context) {
    final primaryColor = _isVideoMode ? Colors.deepOrange : Colors.indigoAccent;

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text("Universal Converter", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: Column(
        children: [
          const SizedBox(height: 20),
          
          // 1. MODE SWITCHER
          ToggleButtons(
            isSelected: [!_isVideoMode, _isVideoMode],
            onPressed: _isProcessing ? null : _toggleMode,
            borderRadius: BorderRadius.circular(30),
            color: Colors.grey.shade600,
            selectedColor: Colors.white,
            fillColor: primaryColor,
            constraints: const BoxConstraints(minWidth: 100, minHeight: 40),
            children: const [
              Row(children: [Icon(Icons.image, size: 18), SizedBox(width: 8), Text("Images")]),
              Row(children: [Icon(Icons.movie, size: 18), SizedBox(width: 8), Text("Videos")]),
            ],
          ),

          // 2. DROP ZONE
          Expanded(
            child: DropTarget(
              onDragDone: _onDragDone,
              onDragEntered: (_) => setState(() => _isHovering = true),
              onDragExited: (_) => setState(() => _isHovering = false),
              child: Column(
                children: [
                  _buildDropZone(primaryColor),
                  _buildControlBar(primaryColor),
                  if (_isProcessing) LinearProgressIndicator(value: _progress, color: primaryColor),
                  Expanded(child: _selectedFiles.isEmpty ? _buildEmptyState() : _buildFileList(primaryColor)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropZone(Color color) {
    return Container(
      width: double.infinity,
      height: 160,
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isHovering ? color.withOpacity(0.1) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _isHovering ? color : Colors.grey.shade300, width: 2),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_isVideoMode ? Icons.movie_creation_outlined : Icons.add_photo_alternate_outlined, size: 50, color: color),
            const SizedBox(height: 10),
            Text("Drag ${_isVideoMode ? 'Videos' : 'Images'} Here", style: TextStyle(fontSize: 18, color: Colors.grey.shade700, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildControlBar(Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          ElevatedButton.icon(
            onPressed: _isProcessing ? null : _pickFiles,
            icon: const Icon(Icons.add),
            label: const Text("Select Files"),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black87),
          ),
          const Spacer(),
          // FORMAT DROPDOWN
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade300)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _isVideoMode ? _targetVideoFormat : _targetImageFormat,
                icon: const Icon(Icons.keyboard_arrow_down),
                items: _isVideoMode 
                  ? ['mp4', 'avi', 'mov', 'mkv', 'gif', 'mp3', 'wav'].map((f) => DropdownMenuItem(value: f, child: Text(f.toUpperCase()))).toList()
                  : ['png', 'jpg', 'webp', 'bmp'].map((f) => DropdownMenuItem(value: f, child: Text(f.toUpperCase()))).toList(),
                onChanged: (v) => setState(() => _isVideoMode ? _targetVideoFormat = v! : _targetImageFormat = v!),
              ),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: _isProcessing || _selectedFiles.isEmpty ? null : _startConversion,
            style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white),
            child: Text(_isProcessing ? "Processing..." : "Convert All"),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Text("No files selected", style: TextStyle(color: Colors.grey.shade400)),
    );
  }

  Widget _buildFileList(Color color) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _selectedFiles.length,
      itemBuilder: (context, index) {
        return Card(
          child: ListTile(
            leading: Icon(_isVideoMode ? Icons.movie : Icons.image, color: color),
            title: Text(_selectedFiles[index].uri.pathSegments.last),
            trailing: IconButton(
              icon: const Icon(Icons.close, color: Colors.redAccent),
              onPressed: () => setState(() => _selectedFiles.removeAt(index)),
            ),
          ),
        );
      },
    );
  }
}