import 'dart:io';
import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'image_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImageService _imageService = ImageService();
  
  List<File> _selectedFiles = [];
  bool _isHovering = false;
  bool _isProcessing = false;
  double _progress = 0.0;
  String _status = "Ready to convert";
  String _targetFormat = 'png'; 

  // --- ACTIONS ---

  void _onDragDone(DropDoneDetails details) {
    setState(() {
      final validFiles = details.files
          .map((e) => File(e.path))
          .where((f) => _isImage(f.path))
          .toList();
      _selectedFiles.addAll(validFiles);
    });
  }

  Future<void> _pickFiles() async {
    // FIX: Using FileType.custom ensures HEIC files are clickable on macOS
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom, 
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'heic', 'bmp'],
    );
    
    if (result != null) {
      setState(() {
        _selectedFiles.addAll(result.paths.map((path) => File(path!)).toList());
      });
    }
  }

  bool _isImage(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ['jpg', 'jpeg', 'png', 'webp', 'heic', 'bmp'].contains(ext);
  }

  Future<void> _startConversion() async {
    if (_selectedFiles.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _progress = 0;
    });

    int successCount = 0;
    String? savePath;
    
    // Get downloads directory for Desktop
    if (Platform.isWindows || Platform.isMacOS) {
      final downloadDir = await getDownloadsDirectory();
      savePath = downloadDir?.path;
    }

    for (int i = 0; i < _selectedFiles.length; i++) {
      File file = _selectedFiles[i];
      setState(() => _status = "Processing ${i + 1}/${_selectedFiles.length}...");

      try {
        var bytes = await _imageService.convertImage(file, _targetFormat);

        if (bytes != null) {
          if (Platform.isWindows || Platform.isMacOS) {
            final name = file.uri.pathSegments.last.split('.').first;
            final newFile = File('$savePath/${name}_converted.$_targetFormat');
            await newFile.writeAsBytes(bytes);
          } else {
            final tempDir = await getTemporaryDirectory();
            final tempFile = File('${tempDir.path}/temp.$_targetFormat');
            await tempFile.writeAsBytes(bytes);
            await Gal.putImage(tempFile.path);
          }
          successCount++;
        } else {
          print("Failed to convert ${file.path}");
        }
      } catch (e) {
        print("Error on file $i: $e");
      }

      setState(() => _progress = (i + 1) / _selectedFiles.length);
    }

    setState(() {
      _isProcessing = false;
      _status = "Success! $successCount images saved.";
      _selectedFiles.clear(); 
    });
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(successCount > 0 
            ? "Success! Saved $successCount images to Downloads." 
            : "Conversion failed. Check if the file is valid."),
          backgroundColor: successCount > 0 ? Colors.green : Colors.red,
        ),
      );
    }
  }

  // --- MODERN UI ---

  @override
  Widget build(BuildContext context) {
    const primaryColor = Colors.indigoAccent;

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text("Universal Converter", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        centerTitle: true,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: DropTarget(
        onDragDone: _onDragDone,
        onDragEntered: (_) => setState(() => _isHovering = true),
        onDragExited: (_) => setState(() => _isHovering = false),
        child: Column(
          children: [
            _buildDropZone(primaryColor),
            _buildControlBar(primaryColor),
            if (_isProcessing) LinearProgressIndicator(value: _progress, minHeight: 6, color: primaryColor),
            Expanded(
              child: _selectedFiles.isEmpty ? _buildEmptyState() : _buildFileList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDropZone(Color color) {
    return Container(
      width: double.infinity,
      height: 180,
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isHovering ? color.withOpacity(0.1) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _isHovering ? color : Colors.grey.shade300,
          width: 2,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_upload_outlined, size: 50, color: color),
            const SizedBox(height: 10),
            Text("Drag & Drop Images Here", style: TextStyle(fontSize: 18, color: Colors.grey.shade700, fontWeight: FontWeight.bold)),
            Text("Supports HEIC, JPG, PNG", style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
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
            icon: const Icon(Icons.add_photo_alternate),
            label: const Text("Select Files"),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade300)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _targetFormat,
                icon: const Icon(Icons.keyboard_arrow_down),
                items: ['png', 'jpg'].map((f) => DropdownMenuItem(value: f, child: Text(f.toUpperCase()))).toList(),
                onChanged: (v) => setState(() => _targetFormat = v!),
              ),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: _isProcessing || _selectedFiles.isEmpty ? null : _startConversion,
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 15),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text(_isProcessing ? "Converting..." : "Convert All"),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_search, size: 60, color: Colors.grey.shade300),
          const SizedBox(height: 10),
          Text("No images selected", style: TextStyle(color: Colors.grey.shade400)),
        ],
      ),
    );
  }

  Widget _buildFileList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _selectedFiles.length,
      itemBuilder: (context, index) {
        final file = _selectedFiles[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: const Icon(Icons.image, size: 40, color: Colors.indigo),
            title: Text(file.uri.pathSegments.last, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text("Ready to convert"),
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