import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

// Mobile FFmpeg
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';

class VideoService {
  // Desktop process reference
  Process? _currentProcess;

  // Mobile session reference
  int? _mobileSessionId;

  bool _isPaused = false;
  bool _isCancelled = false;
  
  // Check platform
  bool get _isDesktop => !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  bool get isPaused => _isPaused;
  bool get isRunning => _currentProcess != null || _mobileSessionId != null;

  Future<bool> convertVideo(
    String inputPath,
    String outputPath, {
    Function(double progress)? onProgress,
  }) async {
    _isPaused = false;
    _isCancelled = false;
    
    // Ensure output directory exists
    final outputDir = Directory(p.dirname(outputPath));
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    if (_isDesktop) {
      return _convertVideoDesktop(inputPath, outputPath, onProgress: onProgress);
    } else {
      return _convertVideoMobile(inputPath, outputPath, onProgress: onProgress);
    }
  }

  // --- Mobile Implementation (iOS/Android) ---
  Future<bool> _convertVideoMobile(
    String inputPath,
    String outputPath, {
    Function(double progress)? onProgress,
  }) async {
    print("Starting Mobile Conversion...");
    
    // 1. Get Duration with FFprobeKit for progress calculation
    final totalDurationMs = await _getDurationMobile(inputPath);
    print("Mobile Duration: $totalDurationMs ms");

    // 2. Build Argument List
    // We determine arguments based on extension, similar to desktop
    final List<String> arguments = [
      '-y', // Overwrite output
      '-i', inputPath,
      ..._getFormatArgs(outputPath),
      outputPath
    ];

    print("FFmpegKit Running args: $arguments");

    final completer = Completer<bool>();

    // 3. Execute Async
    FFmpegKit.executeWithArgumentsAsync(
      arguments,
      (session) async {
        // Complete Callback
        final returnCode = await session.getReturnCode();
        final state = await session.getState();
        _mobileSessionId = null; // Clear session ref

        if (ReturnCode.isSuccess(returnCode)) {
          print("Mobile conversion success");
          onProgress?.call(1.0);
          completer.complete(true);
        } else if (ReturnCode.isCancel(returnCode)) {
          print("Mobile conversion cancelled");
          // Cleanup partial file
          try {
            final file = File(outputPath);
            if (await file.exists()) {
              await file.delete();
            }
          } catch (_) {}
          completer.complete(false);
        } else {
          print("Mobile conversion failed with state $state and rc $returnCode");
          final logs = await session.getAllLogsAsString();
          print("Logs: $logs");
          // Cleanup partial file on failure too
          try {
            final file = File(outputPath);
            if (await file.exists()) {
              await file.delete();
            }
          } catch (_) {}
          completer.complete(false);
        }
      },
      (log) {
        // Log callback (optional, debug usage)
        // print(log.getMessage());
      },
      (statistics) {
        // Statistics Callback (Progress)
        // Store session ID if we haven't yet
        _mobileSessionId = statistics.getSessionId();

        if (totalDurationMs != null && totalDurationMs > 0 && onProgress != null) {
          final timeMs = statistics.getTime(); // time in milliseconds
          double progress = (timeMs / totalDurationMs).clamp(0.0, 1.0);
          onProgress(progress);
        }
      },
    ).then((session) {
       // Save session ID immediately
       _mobileSessionId = session.getSessionId();
    });

    return completer.future;
  }

  // --- Desktop Implementation (Process.start) ---
  Future<bool> _convertVideoDesktop(
    String inputPath,
    String outputPath, {
    Function(double progress)? onProgress,
  }) async {
    final ffmpegPath = await _getFFmpegPath();
    if (ffmpegPath == null) {
      print("FFmpeg not found");
      return false;
    }

    final totalDuration = await _getDurationDesktop(ffmpegPath, inputPath);
    print("Total duration: ${totalDuration?.inSeconds}s");

    final args = [
      '-y',
      '-i',
      inputPath,
      '-progress',
      'pipe:1',
      ..._getFormatArgs(outputPath),
      outputPath,
    ];

    print("Running Desktop: $ffmpegPath ${args.join(' ')}");

    try {
      final process = await Process.start(ffmpegPath, args);
      _currentProcess = process;

      final stdoutCompleter = Completer<void>();
      process.stdout.transform(const SystemEncoding().decoder).listen(
        (data) {
          if (totalDuration != null && onProgress != null) {
            final microseconds = _parseOutTimeMicroseconds(data);
            if (microseconds != null && microseconds > 0) {
              final progress = (microseconds / totalDuration.inMicroseconds).clamp(0.0, 1.0);
              onProgress(progress);
            }
          }
        },
        onDone: () => stdoutCompleter.complete(),
        onError: (e) => stdoutCompleter.complete(),
      );
      
      // Also consume stderr to prevent buffer blocking and maybe get progress if stdout fails?
      // Usually -progress pipe:1 sends to stdout, but let's drain stderr.
      process.stderr.drain();

      final exitCode = await process.exitCode;
      await stdoutCompleter.future;
      _currentProcess = null;

      if (_isCancelled) {
        // Cleanup
        try {
          final file = File(outputPath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
        return false;
      }

      if (exitCode == 0) {
        print("Conversion successful! Output: $outputPath");
        onProgress?.call(1.0);
        return true;
      } else {
        print("FFmpeg exited with code $exitCode");
        return false;
      }
    } catch (e) {
      print("Error running FFmpeg: $e");
      return false;
    }
  }

  // --- Controls ---

  // Pause: Desktop only (signals)
  void pauseConversion() {
    if (_isDesktop) {
      if (_currentProcess != null && !_isPaused) {
        Process.killPid(_currentProcess!.pid, ProcessSignal.sigstop);
        _isPaused = true;
        print("FFmpeg paused (SIGSTOP)");
      }
    } else {
      // Not supported on Mobile FFmpegKit easily
      print("Pause not supported on mobile via FFmpegKit");
    }
  }

  // Resume: Desktop only (signals)
  void resumeConversion() {
    if (_isDesktop) {
      if (_currentProcess != null && _isPaused) {
        Process.killPid(_currentProcess!.pid, ProcessSignal.sigcont);
        _isPaused = false;
        print("FFmpeg resumed (SIGCONT)");
      }
    } else {
      // Not supported on Mobile
    }
  }

  // Stop: Works on both
  void stopConversion() {
    _isCancelled = true;
    if (_isDesktop) {
      if (_currentProcess != null) {
        if (_isPaused) {
          Process.killPid(_currentProcess!.pid, ProcessSignal.sigcont);
          _isPaused = false;
        }
        _currentProcess!.kill(ProcessSignal.sigterm);
        print("FFmpeg desktop stopped (SIGTERM)");
      }
    } else {
      // Mobile - cancel session
      FFmpegKit.cancel(_mobileSessionId);
      print("Mobile FFmpeg session cancelled: $_mobileSessionId");
    }
  }

  // --- Helpers ---

  // Helper args based on extension (Shared logic)
  List<String> _getFormatArgs(String outputPath) {
    final ext = p.extension(outputPath).toLowerCase().replaceAll('.', '');
    switch (ext) {
      case 'mp4':
        return ['-c:v', 'libx264', '-c:a', 'aac', '-preset', 'fast'];
      case 'avi':
        return ['-c:v', 'mpeg4', '-c:a', 'mp3'];
      case 'mov':
      case 'mkv':
        return ['-c:v', 'libx264', '-c:a', 'aac'];
      case 'gif':
        return ['-vf', 'fps=15,scale=480:-1:flags=lanczos', '-loop', '0'];
      case 'mp3':
        return ['-vn', '-acodec', 'libmp3lame', '-q:a', '2']; 
      case 'wav':
        return ['-vn', '-acodec', 'pcm_s16le'];
      default:
        return []; // Default (auto)
    }
  }

  // Desktop: Duration
  Future<Duration?> _getDurationDesktop(String ffmpegPath, String inputPath) async {
    try {
      // Check if audio only stream first if needed, but existing logic used separate check.
      // We'll rely on ffprobe output generally.
      final result = await Process.run(ffmpegPath, ['-i', inputPath]);
      // Duration is in stderr usually
      final output = result.stderr.toString();
      final durationMatch = RegExp(r"Duration: (\d{2}):(\d{2}):(\d{2})\.(\d{2})").firstMatch(output);
      if (durationMatch != null) {
        final hours = int.parse(durationMatch.group(1)!);
        final mins = int.parse(durationMatch.group(2)!);
        final secs = int.parse(durationMatch.group(3)!);
        return Duration(hours: hours, minutes: mins, seconds: secs);
      }
    } catch (e) {
      print("Error getting duration desktop: $e");
    }
    return null;
  }

  // Mobile: Duration (returns in milliseconds for easier calc with Statistics.getTime())
  Future<int?> _getDurationMobile(String inputPath) async {
    try {
      final session = await FFprobeKit.getMediaInformation(inputPath);
      final info = session.getMediaInformation();
      if (info != null) {
        final duration = info.getDuration(); // string in seconds usually
        if (duration != null) {
          final secs = double.tryParse(duration);
          if (secs != null) {
            return (secs * 1000).toInt();
          }
        }
      }
    } catch (e) {
      print("Error getting mobile duration: $e");
    }
    return null;
  }

  // Desktop: Parse Progress
  int? _parseOutTimeMicroseconds(String data) {
    final match = RegExp(r"out_time_us=(\d+)").firstMatch(data);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    // Fallback for some ffmpeg versions
    final timeMatch = RegExp(r'out_time=(\d+):(\d+):(\d+)\.(\d+)').firstMatch(data);
    if (timeMatch != null) {
      final hours = int.parse(timeMatch.group(1)!);
      final mins = int.parse(timeMatch.group(2)!);
      final secs = int.parse(timeMatch.group(3)!);
      final micros = int.parse(timeMatch.group(4)!.padRight(6, '0').substring(0, 6));
      return Duration(hours: hours, minutes: mins, seconds: secs, microseconds: micros).inMicroseconds;
    }
    return null;
  }

  // Desktop: Find ffmpeg binary
  Future<String?> _getFFmpegPath() async {
    if (Platform.isMacOS) {
      return "/opt/homebrew/bin/ffmpeg"; 
    }
    try {
      final cmd = Platform.isWindows ? 'where' : 'which';
      final result = await Process.run(cmd, ['ffmpeg']);
      if (result.exitCode == 0) {
        return result.stdout.toString().trim().split('\n').first;
      }
    } catch (_) {}
    return null;
  }
}