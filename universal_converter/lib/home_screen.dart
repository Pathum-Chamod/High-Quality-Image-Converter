import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'image_service.dart';
import 'video_service.dart';

// --- File status model ---
enum FileStatus { pending, processing, success, failed, cancelled }

class ConvertFile {
  final File file;
  FileStatus status;
  String? errorMessage;
  bool isHighlighted;
  double fileProgress; // 0.0 to 1.0 for current file

  ConvertFile({
    required this.file,
    this.status = FileStatus.pending,
    this.errorMessage,
    this.isHighlighted = false,
    this.fileProgress = 0.0,
  });

  String get fileName => file.uri.pathSegments.last;
  String get extension => fileName.split('.').last.toUpperCase();
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final ImageService _imageService = ImageService();
  final VideoService _videoService = VideoService();

  bool _isVideoMode = false;
  final List<ConvertFile> _files = [];
  bool _isHovering = false;
  bool _isProcessing = false;
  bool _isPaused = false;
  bool _batchCancelled = false;
  double _progress = 0.0;
  String _status = "Ready";

  String _targetImageFormat = 'png';
  String _targetVideoFormat = 'mp4';

  // Notification panel
  bool _showNotifications = false;

  // Scroll controller for auto-scrolling to highlighted file
  final ScrollController _scrollController = ScrollController();

  late AnimationController _pulseController;
  late AnimationController _gradientController;
  late AnimationController _notificationBounce;
  late Animation<double> _pulseAnimation;

  // --- Theme-aware helpers ---
  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  Color get _bgColor => _isDark ? const Color(0xFF0F0F1A) : const Color(0xFFF5F5FA);
  Color get _cardBg => _isDark ? const Color(0xFF1A1A2E) : Colors.white;
  Color get _cardBorder => _isDark ? const Color(0xFF2A2A40) : const Color(0xFFE2E2EE);
  Color get _surfaceLight => _isDark ? const Color(0xFF16213E) : const Color(0xFFEEEEF5);
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white60 : const Color(0xFF6B6B80);
  Color get _textTertiary => _isDark ? Colors.white24 : const Color(0xFFAAAAAA);

  List<Color> get _accentGradient => _isVideoMode
      ? [const Color(0xFFFF6B35), const Color(0xFFFF2E63)]
      : [const Color(0xFF6C63FF), const Color(0xFF3B82F6)];

  Color get _accentPrimary =>
      _isVideoMode ? const Color(0xFFFF6B35) : const Color(0xFF6C63FF);

  // Derived lists
  List<ConvertFile> get _failedFiles => _files.where((f) => f.status == FileStatus.failed || f.status == FileStatus.cancelled).toList();
  List<ConvertFile> get _successFiles => _files.where((f) => f.status == FileStatus.success).toList();
  int get _errorCount => _files.where((f) => f.status == FileStatus.failed).length;
  int get _cancelledCount => _files.where((f) => f.status == FileStatus.cancelled).length;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _gradientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    _notificationBounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _gradientController.dispose();
    _notificationBounce.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // --- ACTIONS ---

  void _onDragDone(DropDoneDetails details) {
    setState(() {
      final validFiles = details.files
          .map((e) => File(e.path))
          .where((f) => _isVideoMode ? _isVideo(f.path) : _isImage(f.path))
          .map((f) => ConvertFile(file: f))
          .toList();
      _files.addAll(validFiles);
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
        _files.addAll(
          result.paths.map((path) => ConvertFile(file: File(path!))).toList(),
        );
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

  void _toggleMode(bool isVideo) {
    setState(() {
      _isVideoMode = isVideo;
      _files.clear();
      _status = "Switched to ${_isVideoMode ? 'Video' : 'Image'} mode";
      _showNotifications = false;
    });
  }

  void _removeFile(int index) {
    setState(() {
      _files.removeAt(index);
      if (_errorCount == 0) _showNotifications = false;
    });
  }

  void _clearAll() {
    setState(() {
      _files.clear();
      _showNotifications = false;
    });
  }

  void _clearCompleted() {
    setState(() {
      _files.removeWhere((f) => f.status == FileStatus.success);
    });
  }

  Future<void> _retryFile(int index) async {
    final cf = _files[index];
    cf.status = FileStatus.pending;
    cf.errorMessage = null;
    cf.isHighlighted = false;
    cf.fileProgress = 0.0;
    setState(() {});
    await _convertSingleFile(index);
  }

  Future<void> _retryAllFailed() async {
    // Reset all failed/cancelled files to pending
    for (var f in _files) {
      if (f.status == FileStatus.failed || f.status == FileStatus.cancelled) {
        f.status = FileStatus.pending;
        f.errorMessage = null;
        f.isHighlighted = false;
        f.fileProgress = 0.0;
      }
    }
    setState(() {
      _showNotifications = false;
    });
    await _startConversion();
  }

  // --- Pause / Resume / Stop ---

  void _pauseConversion() {
    if (_isVideoMode) {
      _videoService.pauseConversion();
    }
    setState(() {
      _isPaused = true;
      _status = "Paused";
    });
  }

  void _resumeConversion() {
    if (_isVideoMode) {
      _videoService.resumeConversion();
    }
    setState(() {
      _isPaused = false;
      _status = "Resuming...";
    });
  }

  void _stopCurrentFile() {
    if (_isVideoMode) {
      _videoService.stopConversion();
    }
    // Mark current processing file as cancelled
    for (var f in _files) {
      if (f.status == FileStatus.processing) {
        f.status = FileStatus.cancelled;
        f.errorMessage = "Cancelled by user";
        f.fileProgress = 0.0;
      }
    }
    setState(() {
      _isPaused = false;
      _status = "Cancelled current file";
    });
  }

  void _stopAllConversion() {
    _batchCancelled = true;
    if (_isVideoMode) {
      _videoService.stopConversion();
    }
    // Mark current processing file as cancelled
    for (var f in _files) {
      if (f.status == FileStatus.processing) {
        f.status = FileStatus.cancelled;
        f.errorMessage = "Cancelled by user";
        f.fileProgress = 0.0;
      }
    }
    // Mark remaining pending files as cancelled too
    for (var f in _files) {
      if (f.status == FileStatus.pending) {
        f.status = FileStatus.cancelled;
        f.errorMessage = "Batch cancelled";
      }
    }
    setState(() {
      _isProcessing = false;
      _isPaused = false;
      _status = "All conversions stopped";
    });
  }

  void _highlightFile(ConvertFile cf) {
    setState(() {
      // Remove all highlights first
      for (var f in _files) {
        f.isHighlighted = false;
      }
      cf.isHighlighted = true;
      _showNotifications = false;
    });

    // Scroll to the highlighted file
    final index = _files.indexOf(cf);
    if (index >= 0) {
      // Approximate position calculation
      // Each card is ~74px + 8px margin = ~82px, plus header area
      final targetOffset = index * 82.0;
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
      );
    }

    // Remove highlight after a delay
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => cf.isHighlighted = false);
      }
    });
  }

  Future<void> _startConversion() async {
    _batchCancelled = false;
    final pendingIndices = <int>[];
    for (int i = 0; i < _files.length; i++) {
      if (_files[i].status == FileStatus.pending) pendingIndices.add(i);
    }
    if (pendingIndices.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _isPaused = false;
      _progress = 0;
    });

    int processed = 0;
    final total = pendingIndices.length;

    for (final i in pendingIndices) {
      // Check if batch was cancelled
      if (_batchCancelled) break;
      await _convertSingleFile(i);
      processed++;
      setState(() => _progress = processed / total);
    }

    setState(() {
      _isProcessing = false;
      _isPaused = false;
      _status = _batchCancelled ? "Stopped" : "Done!";
    });

    // Bounce the notification bell if there are errors
    if (_errorCount > 0) {
      _notificationBounce.forward(from: 0);
    }

    if (mounted) {
      final successCount = _successFiles.length;
      final failedCount = _files.where((f) => f.status == FileStatus.failed).length;
      final cancelledCount = _cancelledCount;

      String message;
      Color bgColor;
      if (failedCount == 0 && cancelledCount == 0) {
        message = "✅ All $successCount files converted successfully!";
        bgColor = const Color(0xFF22C55E);
      } else if (cancelledCount > 0 && failedCount == 0) {
        message = "⚠️ $successCount converted, $cancelledCount cancelled.";
        bgColor = const Color(0xFFF59E0B);
      } else if (successCount > 0) {
        message = "⚠️ $successCount converted, $failedCount failed, $cancelledCount cancelled.";
        bgColor = const Color(0xFFF59E0B);
      } else {
        message = "❌ All conversions failed. Tap 🔔 for details.";
        bgColor = const Color(0xFFEF4444);
      }

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: bgColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      ));
    }
  }

  Future<void> _convertSingleFile(int index) async {
    final cf = _files[index];
    setState(() {
      cf.status = FileStatus.processing;
      cf.fileProgress = 0.0;
      _status = "Converting ${cf.fileName}...";
    });

    String? savePath;
    if (Platform.isWindows || Platform.isMacOS) {
      final downloadDir = await getDownloadsDirectory();
      savePath = downloadDir?.path;
    }

    try {
      bool success = false;
      String? errorMsg;

      if (_isVideoMode) {
        String newPath;
        final name = cf.fileName.split('.').first;

        if (Platform.isWindows || Platform.isMacOS) {
          newPath = '$savePath/${name}_converted.$_targetVideoFormat';
        } else {
          final tempDir = await getTemporaryDirectory();
          newPath = '${tempDir.path}/$name.$_targetVideoFormat';
        }

        success = await _videoService.convertVideo(
          cf.file.path, 
          newPath,
          onProgress: (progress) {
            if (mounted) {
              setState(() {
                cf.fileProgress = progress;
                _status = "Converting ${cf.fileName}... ${(progress * 100).toInt()}%";
              });
            }
          },
        );
        if (!success) {
          // Check if it was user cancellation
          if (_batchCancelled || _videoService.isPaused == false && cf.fileProgress > 0) {
            // Could be a cancellation — check cancelled flag
          }
          final isAudioTarget = _targetVideoFormat == 'mp3' || _targetVideoFormat == 'wav';
          errorMsg = isAudioTarget
              ? "No audio track found in video"
              : "FFmpeg conversion failed";
        }

        if (success && (Platform.isAndroid || Platform.isIOS)) {
          await Gal.putVideo(newPath);
          File(newPath).delete();
        }
      } else {
        // Image conversions are quick — just show indeterminate
        setState(() => cf.fileProgress = -1.0); // -1 = indeterminate
        
        if (_batchCancelled) {
          setState(() {
            cf.status = FileStatus.cancelled;
            cf.errorMessage = "Cancelled by user";
            cf.fileProgress = 0.0;
          });
          return;
        }
        
        var bytes = await _imageService.convertImage(cf.file, _targetImageFormat);
        if (bytes != null) {
          if (Platform.isWindows || Platform.isMacOS) {
            final name = cf.fileName.split('.').first;
            final newFile = File('$savePath/${name}_converted.$_targetImageFormat');
            await newFile.writeAsBytes(bytes);
          } else {
            final tempDir = await getTemporaryDirectory();
            final tempFile = File('${tempDir.path}/temp.$_targetImageFormat');
            await tempFile.writeAsBytes(bytes);
            await Gal.putImage(tempFile.path);
          }
          success = true;
        } else {
          errorMsg = "Image conversion returned empty result";
        }
      }

      // Check if the file was already marked as cancelled by stop action
      if (cf.status == FileStatus.cancelled) return;

      setState(() {
        cf.status = success ? FileStatus.success : FileStatus.failed;
        cf.errorMessage = errorMsg;
        cf.fileProgress = success ? 1.0 : 0.0;
      });
    } catch (e) {
      // If cancelled, keep cancelled status
      if (cf.status == FileStatus.cancelled) return;
      setState(() {
        cf.status = FileStatus.failed;
        cf.errorMessage = e.toString();
        cf.fileProgress = 0.0;
      });
    }
  }

  // ============================
  //           UI BUILD
  // ============================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: Stack(
        children: [
          _buildBackgroundOrbs(),
          SafeArea(
            child: Column(
              children: [
                _buildAppBar(),
                const SizedBox(height: 16),
                _buildModeSwitcher(),
                const SizedBox(height: 20),
                Expanded(
                  child: DropTarget(
                    onDragDone: _onDragDone,
                    onDragEntered: (_) => setState(() => _isHovering = true),
                    onDragExited: (_) => setState(() => _isHovering = false),
                    child: Stack(
                      children: [
                        SingleChildScrollView(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            children: [
                              _buildDropZone(),
                              const SizedBox(height: 20),
                              _buildControlBar(),
                              if (_isProcessing) ...[
                                const SizedBox(height: 16),
                                _buildProgressSection(),
                              ],
                              const SizedBox(height: 16),
                              _buildFileSection(),
                              const SizedBox(height: 24),
                            ],
                          ),
                        ),
                        // Notification panel overlay
                        if (_showNotifications) _buildNotificationPanel(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Animated error toast
          if (_isProcessing) _buildAnimatedStatusMessage(),
        ],
      ),
    );
  }

  // --- Background orbs ---
  Widget _buildBackgroundOrbs() {
    return AnimatedBuilder(
      animation: _gradientController,
      builder: (context, child) {
        return Stack(
          children: [
            Positioned(
              top: -80 + 20 * sin(_gradientController.value * 2 * pi),
              right: -60 + 15 * cos(_gradientController.value * 2 * pi),
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      _accentGradient[0].withValues(alpha: _isDark ? 0.12 : 0.08),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -100 + 25 * sin(_gradientController.value * 2 * pi + 1),
              left: -80 + 20 * cos(_gradientController.value * 2 * pi + 1),
              child: Container(
                width: 350,
                height: 350,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      _accentGradient[1].withValues(alpha: _isDark ? 0.10 : 0.06),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // --- App Bar ---
  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(
                colors: _accentGradient,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: _accentGradient[0].withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(Icons.transform_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Universal Converter",
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: _textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              Text(
                _isVideoMode ? "Video conversion engine" : "Image conversion engine",
                style: TextStyle(fontSize: 13, color: _textTertiary, letterSpacing: 0.3),
              ),
            ],
          ),
          const Spacer(),

          // Notification bell
          if (_errorCount > 0) _buildNotificationBell(),
          const SizedBox(width: 12),

          // Status pill
          _buildStatusPill(),
        ],
      ),
    );
  }

  Widget _buildNotificationBell() {
    return AnimatedBuilder(
      animation: _notificationBounce,
      builder: (context, child) {
        final bounce = sin(_notificationBounce.value * pi * 4) * 
            (1 - _notificationBounce.value) * 8;
        return Transform.translate(
          offset: Offset(0, bounce),
          child: GestureDetector(
            onTap: () => setState(() => _showNotifications = !_showNotifications),
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                border: Border.all(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    _showNotifications 
                        ? Icons.notifications_active_rounded 
                        : Icons.notifications_rounded,
                    size: 20,
                    color: const Color(0xFFEF4444),
                  ),
                  // Badge
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFFEF4444),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFEF4444).withValues(alpha: 0.5),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                      child: Center(
                        child: Text(
                          '$_errorCount',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusPill() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: _isProcessing
            ? _accentPrimary.withValues(alpha: 0.12)
            : (_isDark
                ? const Color(0xFF1E3A1E).withValues(alpha: 0.6)
                : const Color(0xFFDCFCE7)),
        border: Border.all(
          color: _isProcessing
              ? _accentPrimary.withValues(alpha: 0.3)
              : const Color(0xFF4ADE80).withValues(alpha: _isDark ? 0.2 : 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7, height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isProcessing ? _accentPrimary : const Color(0xFF22C55E),
              boxShadow: [
                BoxShadow(
                  color: (_isProcessing ? _accentPrimary : const Color(0xFF22C55E))
                      .withValues(alpha: 0.5),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _isProcessing ? "Processing" : "Ready",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _isProcessing ? _accentPrimary : const Color(0xFF22C55E),
            ),
          ),
        ],
      ),
    );
  }

  // --- Mode Switcher ---
  Widget _buildModeSwitcher() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _cardBorder, width: 1),
          boxShadow: _isDark ? [] : [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            _buildModeTab(icon: Icons.image_rounded, label: "Images", isActive: !_isVideoMode, onTap: () => _toggleMode(false)),
            _buildModeTab(icon: Icons.movie_filter_rounded, label: "Videos", isActive: _isVideoMode, onTap: () => _toggleMode(true)),
          ],
        ),
      ),
    );
  }

  Widget _buildModeTab({required IconData icon, required String label, required bool isActive, required VoidCallback onTap}) {
    return Expanded(
      child: GestureDetector(
        onTap: _isProcessing ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: isActive ? LinearGradient(colors: _accentGradient, begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
            boxShadow: isActive ? [BoxShadow(color: _accentGradient[0].withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))] : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: isActive ? Colors.white : _textTertiary),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(fontSize: 15, fontWeight: isActive ? FontWeight.w700 : FontWeight.w500, color: isActive ? Colors.white : _textTertiary, letterSpacing: 0.3)),
            ],
          ),
        ),
      ),
    );
  }

  // --- Drop Zone ---
  Widget _buildDropZone() {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: _isHovering ? 1.02 : 1.0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 44),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: _isHovering ? _accentPrimary.withValues(alpha: _isDark ? 0.08 : 0.05) : _cardBg,
              border: Border.all(color: _isHovering ? _accentPrimary.withValues(alpha: 0.6) : _cardBorder, width: _isHovering ? 2 : 1),
              boxShadow: [
                if (_isHovering) BoxShadow(color: _accentPrimary.withValues(alpha: 0.15), blurRadius: 30, spreadRadius: 2),
                if (!_isDark) BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 16, offset: const Offset(0, 4)),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ScaleTransition(
                  scale: _pulseAnimation,
                  child: Container(
                    width: 72, height: 72,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: LinearGradient(colors: [_accentGradient[0].withValues(alpha: 0.15), _accentGradient[1].withValues(alpha: 0.08)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                      border: Border.all(color: _accentPrimary.withValues(alpha: 0.2)),
                    ),
                    child: Icon(_isVideoMode ? Icons.movie_creation_rounded : Icons.add_photo_alternate_rounded, size: 34, color: _accentPrimary),
                  ),
                ),
                const SizedBox(height: 18),
                Text("Drop your ${_isVideoMode ? 'videos' : 'images'} here", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: _textPrimary, letterSpacing: -0.3)),
                const SizedBox(height: 6),
                Text(
                  _isVideoMode ? "Supports MP4, MOV, AVI, MKV, FLV, WebM, WMV, GIF" : "Supports JPG, PNG, WebP, HEIC, BMP, TIFF",
                  style: TextStyle(fontSize: 13, color: _textTertiary, letterSpacing: 0.2),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(width: 40, height: 1, color: _cardBorder),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text("or", style: TextStyle(fontSize: 13, color: _textTertiary))),
                    Container(width: 40, height: 1, color: _cardBorder),
                  ],
                ),
                const SizedBox(height: 20),
                _buildGlassButton(icon: Icons.folder_open_rounded, label: "Browse Files", onTap: _isProcessing ? null : _pickFiles),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGlassButton({required IconData icon, required String label, VoidCallback? onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: _isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04),
            border: Border.all(color: _isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: _textSecondary),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _textSecondary)),
            ],
          ),
        ),
      ),
    );
  }

  // --- Control Bar ---
  Widget _buildControlBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _cardBorder),
        boxShadow: _isDark ? [] : [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          // File count with status breakdown
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: _surfaceLight),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.insert_drive_file_rounded, size: 16, color: _textTertiary),
                const SizedBox(width: 8),
                Text(
                  "${_files.length} file${_files.length != 1 ? 's' : ''}",
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _textSecondary),
                ),
                if (_successFiles.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: const Color(0xFF22C55E).withValues(alpha: 0.15),
                    ),
                    child: Text('${_successFiles.length}✓', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF22C55E))),
                  ),
                ],
                if (_failedFiles.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: const Color(0xFFEF4444).withValues(alpha: 0.15),
                    ),
                    child: Text('${_failedFiles.length}✗', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFFEF4444))),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Icon(Icons.arrow_forward_rounded, size: 18, color: _textTertiary),
          const SizedBox(width: 12),
          // Format dropdown
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: _surfaceLight,
              border: Border.all(color: _accentPrimary.withValues(alpha: 0.3)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _isVideoMode ? _targetVideoFormat : _targetImageFormat,
                icon: Icon(Icons.keyboard_arrow_down_rounded, color: _accentPrimary, size: 20),
                dropdownColor: _cardBg,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _accentPrimary, letterSpacing: 0.5),
                items: _isVideoMode
                    ? ['mp4', 'avi', 'mov', 'mkv', 'gif', 'mp3', 'wav'].map((f) => DropdownMenuItem(value: f, child: Text(f.toUpperCase()))).toList()
                    : ['png', 'jpg', 'webp', 'bmp'].map((f) => DropdownMenuItem(value: f, child: Text(f.toUpperCase()))).toList(),
                onChanged: (v) => setState(() => _isVideoMode ? _targetVideoFormat = v! : _targetImageFormat = v!),
              ),
            ),
          ),
          const Spacer(),
          _buildConvertButton(),
        ],
      ),
    );
  }

  Widget _buildConvertButton() {
    final hasPending = _files.any((f) => f.status == FileStatus.pending);
    final isEnabled = !_isProcessing && _files.isNotEmpty && hasPending;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isEnabled ? _startConversion : null,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: isEnabled ? LinearGradient(colors: _accentGradient, begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
            color: isEnabled ? null : _surfaceLight,
            boxShadow: isEnabled ? [BoxShadow(color: _accentGradient[0].withValues(alpha: 0.4), blurRadius: 16, offset: const Offset(0, 6))] : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_isProcessing ? Icons.hourglass_top_rounded : Icons.bolt_rounded, size: 18, color: isEnabled ? Colors.white : _textTertiary),
              const SizedBox(width: 8),
              Text(
                _isProcessing ? "Converting..." : "Convert All",
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: isEnabled ? Colors.white : _textTertiary, letterSpacing: 0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Progress Section ---
  Widget _buildProgressSection() {
    // Find the currently processing file
    final currentFile = _files.where((f) => f.status == FileStatus.processing).firstOrNull;
    final fileProgress = currentFile?.fileProgress ?? 0.0;
    final isIndeterminate = fileProgress < 0; // -1 means indeterminate (images)

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _accentPrimary.withValues(alpha: 0.2)),
        boxShadow: _isDark ? [] : [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 2))],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.sync_rounded, size: 18, color: _accentPrimary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _status, 
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _textPrimary), 
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!isIndeterminate)
                Text(
                  "${(fileProgress * 100).toInt()}%", 
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _accentPrimary),
                ),
            ],
          ),
          const SizedBox(height: 14),
          // Per-file progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: isIndeterminate
                ? LinearProgressIndicator(
                    backgroundColor: _surfaceLight, 
                    valueColor: AlwaysStoppedAnimation<Color>(_accentPrimary), 
                    minHeight: 6,
                  )
                : LinearProgressIndicator(
                    value: fileProgress, 
                    backgroundColor: _surfaceLight, 
                    valueColor: AlwaysStoppedAnimation<Color>(_accentPrimary), 
                    minHeight: 6,
                  ),
          ),
          // Overall batch progress (subtle)
          if (_files.where((f) => f.status == FileStatus.pending || f.status == FileStatus.processing).length > 1) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  "Overall: ${(_progress * 100).toInt()}%",
                  style: TextStyle(fontSize: 12, color: _textTertiary, fontWeight: FontWeight.w500),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _progress, 
                      backgroundColor: _surfaceLight, 
                      valueColor: AlwaysStoppedAnimation<Color>(_accentPrimary.withValues(alpha: 0.4)), 
                      minHeight: 3,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // --- Animated status message (during processing) ---
  Widget _buildAnimatedStatusMessage() {
    return Positioned(
      bottom: 20,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: _isProcessing ? 1.0 : 0.0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: _accentPrimary.withValues(alpha: 0.9),
                  boxShadow: [
                    BoxShadow(
                      color: _accentPrimary.withValues(alpha: 0.4),
                      blurRadius: 20,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _status,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // --- Notification Panel ---
  Widget _buildNotificationPanel() {
    return Positioned(
      top: 0,
      right: 24,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: _showNotifications ? 1.0 : 0.0,
        child: Container(
          width: 340,
          constraints: const BoxConstraints(maxHeight: 300),
          decoration: BoxDecoration(
            color: _cardBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                child: Row(
                  children: [
                    const Icon(Icons.error_rounded, size: 18, color: Color(0xFFEF4444)),
                    const SizedBox(width: 8),
                    Text(
                      "Failed Conversions",
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _textPrimary),
                    ),
                    const Spacer(),
                    // Retry all button
                    if (_failedFiles.isNotEmpty)
                      GestureDetector(
                        onTap: _isProcessing ? null : _retryAllFailed,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: _accentPrimary.withValues(alpha: 0.12),
                          ),
                          child: Text("Retry all", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _accentPrimary)),
                        ),
                      ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setState(() => _showNotifications = false),
                      child: Icon(Icons.close_rounded, size: 18, color: _textTertiary),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: _cardBorder),
              // Error list
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _failedFiles.length,
                  itemBuilder: (context, index) {
                    final cf = _failedFiles[index];
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _highlightFile(cf),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          child: Row(
                            children: [
                              Container(
                                width: 32, height: 32,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                                ),
                                child: const Icon(Icons.warning_rounded, size: 16, color: Color(0xFFEF4444)),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      cf.fileName,
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _textPrimary),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      cf.errorMessage ?? "Unknown error",
                                      style: TextStyle(fontSize: 11, color: const Color(0xFFEF4444).withValues(alpha: 0.8)),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(Icons.arrow_forward_ios_rounded, size: 12, color: _textTertiary),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- File Section ---
  Widget _buildFileSection() {
    if (_files.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 50),
        child: Column(
          children: [
            Icon(Icons.cloud_upload_outlined, size: 48, color: _textTertiary),
            const SizedBox(height: 12),
            Text("No files selected yet", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _textTertiary)),
            const SizedBox(height: 6),
            Text("Drag & drop or browse to add files", style: TextStyle(fontSize: 13, color: _textTertiary.withValues(alpha: _isDark ? 0.5 : 0.4))),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Text("Selected Files", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _textPrimary)),
            const Spacer(),
            if (_successFiles.isNotEmpty)
              GestureDetector(
                onTap: _clearCompleted,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: const Color(0xFF22C55E).withValues(alpha: 0.1),
                  ),
                  child: const Text("Clear done", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF22C55E))),
                ),
              ),
            GestureDetector(
              onTap: _isProcessing ? null : _clearAll,
              child: Text("Clear all", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _accentPrimary.withValues(alpha: 0.7))),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...List.generate(_files.length, (i) => _buildFileCard(i)),
      ],
    );
  }

  Widget _buildFileCard(int index) {
    final cf = _files[index];

    Color statusColor;
    IconData statusIcon;
    switch (cf.status) {
      case FileStatus.pending:
        statusColor = _textTertiary;
        statusIcon = Icons.hourglass_empty_rounded;
        break;
      case FileStatus.processing:
        statusColor = _accentPrimary;
        statusIcon = Icons.sync_rounded;
        break;
      case FileStatus.success:
        statusColor = const Color(0xFF22C55E);
        statusIcon = Icons.check_circle_rounded;
        break;
      case FileStatus.failed:
        statusColor = const Color(0xFFEF4444);
        statusIcon = Icons.error_rounded;
        break;
    }

    // Highlight border for error files
    final highlightBorder = cf.isHighlighted
        ? Border.all(color: const Color(0xFFEF4444), width: 2)
        : Border.all(color: cf.status == FileStatus.failed ? const Color(0xFFEF4444).withValues(alpha: 0.3) : _cardBorder);

    final highlightBg = cf.isHighlighted
        ? const Color(0xFFEF4444).withValues(alpha: _isDark ? 0.08 : 0.04)
        : _cardBg;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: highlightBg,
        borderRadius: BorderRadius.circular(16),
        border: highlightBorder,
        boxShadow: [
          if (cf.isHighlighted)
            BoxShadow(
              color: const Color(0xFFEF4444).withValues(alpha: 0.2),
              blurRadius: 16,
              spreadRadius: 2,
            ),
          if (!_isDark && !cf.isHighlighted)
            BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              // File type badge with status
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(colors: [
                    statusColor.withValues(alpha: 0.15),
                    statusColor.withValues(alpha: 0.05),
                  ]),
                ),
                child: Center(
                  child: cf.status == FileStatus.processing
                      ? cf.fileProgress > 0
                          ? Stack(
                              alignment: Alignment.center,
                              children: [
                                SizedBox(
                                  width: 30, height: 30,
                                  child: CircularProgressIndicator(
                                    value: cf.fileProgress,
                                    strokeWidth: 2.5,
                                    valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                                    backgroundColor: statusColor.withValues(alpha: 0.15),
                                  ),
                                ),
                                Text(
                                  '${(cf.fileProgress * 100).toInt()}',
                                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: statusColor),
                                ),
                              ],
                            )
                          : SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                              ),
                            )
                      : Text(
                          cf.extension,
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: statusColor, letterSpacing: 0.5),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              // File info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cf.fileName,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _textPrimary),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    if (cf.status == FileStatus.failed && cf.errorMessage != null)
                      Text(
                        cf.errorMessage!,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFFEF4444)),
                        overflow: TextOverflow.ellipsis,
                      )
                    else
                      Row(
                        children: [
                          Icon(statusIcon, size: 12, color: statusColor),
                          const SizedBox(width: 4),
                          Text(
                            cf.status == FileStatus.pending
                                ? "→ ${_isVideoMode ? _targetVideoFormat.toUpperCase() : _targetImageFormat.toUpperCase()}"
                                : cf.status == FileStatus.processing
                                    ? "Converting... ${cf.fileProgress > 0 ? '${(cf.fileProgress * 100).toInt()}%' : ''}"
                                    : "Converted ✓",
                            style: TextStyle(fontSize: 12, color: statusColor, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              // Action buttons
              if (cf.status == FileStatus.failed) ...[
                // Retry button
                _buildFileAction(
                  icon: Icons.refresh_rounded,
                  color: _accentPrimary,
                  onTap: _isProcessing ? null : () => _retryFile(index),
                  tooltip: "Retry",
                ),
                const SizedBox(width: 6),
              ],
              // Close/remove button
              if (cf.status != FileStatus.processing)
                _buildFileAction(
                  icon: Icons.close_rounded,
                  color: const Color(0xFFEF4444),
                  onTap: () => _removeFile(index),
                  tooltip: "Remove",
                ),
            ],
          ),
          // Mini progress bar for currently converting file
          if (cf.status == FileStatus.processing && cf.fileProgress > 0) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: cf.fileProgress,
                backgroundColor: statusColor.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                minHeight: 3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFileAction({
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: color.withValues(alpha: 0.1),
            ),
            child: Icon(icon, size: 16, color: color),
          ),
        ),
      ),
    );
  }
}