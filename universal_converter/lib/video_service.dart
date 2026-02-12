import 'dart:io';
import 'dart:async';

class VideoService {
  Process? _currentProcess;
  bool _isPaused = false;
  bool _isCancelled = false;

  bool get isPaused => _isPaused;
  bool get isRunning => _currentProcess != null;

  /// Pauses the current FFmpeg conversion (SIGSTOP)
  void pauseConversion() {
    if (_currentProcess != null && !_isPaused) {
      Process.killPid(_currentProcess!.pid, ProcessSignal.sigstop);
      _isPaused = true;
      print("FFmpeg paused (SIGSTOP)");
    }
  }

  /// Resumes the current FFmpeg conversion (SIGCONT)
  void resumeConversion() {
    if (_currentProcess != null && _isPaused) {
      Process.killPid(_currentProcess!.pid, ProcessSignal.sigcont);
      _isPaused = false;
      print("FFmpeg resumed (SIGCONT)");
    }
  }

  /// Stops (kills) the current FFmpeg conversion
  void stopConversion() {
    _isCancelled = true;
    if (_currentProcess != null) {
      // Resume first if paused, then kill
      if (_isPaused) {
        Process.killPid(_currentProcess!.pid, ProcessSignal.sigcont);
        _isPaused = false;
      }
      _currentProcess!.kill(ProcessSignal.sigterm);
      print("FFmpeg stopped (SIGTERM)");
    }
  }

  /// Converts video with real-time progress reporting
  /// [onProgress] callback receives a value from 0.0 to 1.0
  /// Returns true on success, false on failure/cancellation
  Future<bool> convertVideo(
    String inputPath, 
    String outputPath, {
    void Function(double progress)? onProgress,
  }) async {
    _isCancelled = false;
    _isPaused = false;

    try {
      final ffmpegPath = await _findFFmpeg();
      
      if (ffmpegPath == null) {
        print("Error: FFmpeg not found. Install it via 'brew install ffmpeg'.");
        return false;
      }

      print("Using FFmpeg at: $ffmpegPath");
      print("Input: $inputPath");
      print("Output: $outputPath");

      final ext = outputPath.split('.').last.toLowerCase();
      final isAudioOnly = (ext == 'mp3' || ext == 'wav');

      // Check for audio stream if extracting audio
      if (isAudioOnly) {
        final hasAudio = await _hasAudioStream(ffmpegPath, inputPath);
        if (!hasAudio) {
          print("Error: Input file has no audio stream to extract.");
          return false;
        }
      }

      // 1. Get total duration for progress calculation
      final totalDuration = await _getFileDuration(ffmpegPath, inputPath);
      print("Total duration: ${totalDuration?.inSeconds}s");

      // 2. Build FFmpeg arguments
      List<String> args = [
        '-i', inputPath, 
        '-y',
        '-progress', 'pipe:1',
      ];
      
      switch (ext) {
        case 'mp4':
          args.addAll(['-c:v', 'libx264', '-c:a', 'aac', '-preset', 'fast']);
          break;
        case 'avi':
          args.addAll(['-c:v', 'mpeg4', '-c:a', 'mp3']);
          break;
        case 'mov':
          args.addAll(['-c:v', 'libx264', '-c:a', 'aac']);
          break;
        case 'mkv':
          args.addAll(['-c:v', 'libx264', '-c:a', 'aac']);
          break;
        case 'gif':
          args.addAll([
            '-vf', 'fps=15,scale=480:-1:flags=lanczos',
            '-loop', '0',
          ]);
          break;
        case 'mp3':
          args.addAll(['-vn', '-c:a', 'libmp3lame', '-q:a', '2']);
          break;
        case 'wav':
          args.addAll(['-vn', '-c:a', 'pcm_s16le']);
          break;
        default:
          break;
      }
      
      args.add(outputPath);

      // 3. Start the process (streaming, non-blocking)
      _currentProcess = await Process.start(ffmpegPath, args);
      final process = _currentProcess!;

      // 4. Parse progress from stdout (-progress pipe:1)
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
      );

      // Also consume stderr
      final stderrBuffer = StringBuffer();
      final stderrCompleter = Completer<void>();
      process.stderr.transform(const SystemEncoding().decoder).listen(
        (data) {
          stderrBuffer.write(data);
          if (totalDuration != null && onProgress != null) {
            final timeMatch = RegExp(r'time=(\d+):(\d+):(\d+)\.(\d+)').firstMatch(data);
            if (timeMatch != null) {
              final hours = int.parse(timeMatch.group(1)!);
              final minutes = int.parse(timeMatch.group(2)!);
              final seconds = int.parse(timeMatch.group(3)!);
              final currentDuration = Duration(hours: hours, minutes: minutes, seconds: seconds);
              final progress = (currentDuration.inMicroseconds / totalDuration.inMicroseconds).clamp(0.0, 1.0);
              onProgress(progress);
            }
          }
        },
        onDone: () => stderrCompleter.complete(),
      );

      // 5. Wait for process to complete
      final exitCode = await process.exitCode;
      await Future.wait([stdoutCompleter.future, stderrCompleter.future]);
      _currentProcess = null;
      _isPaused = false;

      // Check if cancelled
      if (_isCancelled) {
        // Clean up partial output file
        try {
          final partialFile = File(outputPath);
          if (await partialFile.exists()) {
            await partialFile.delete();
          }
        } catch (_) {}
        print("Conversion cancelled by user.");
        return false;
      }

      if (exitCode == 0) {
        final outputFile = File(outputPath);
        if (await outputFile.exists() && await outputFile.length() > 0) {
          print("Conversion successful! Output: $outputPath");
          onProgress?.call(1.0);
          return true;
        } else {
          print("FFmpeg exited OK but output file is missing or empty.");
          return false;
        }
      } else {
        print("FFmpeg Error (exit code $exitCode)");
        return false;
      }
    } catch (e) {
      _currentProcess = null;
      _isPaused = false;
      print("System Error during video conversion: $e");
      return false;
    }
  }

  /// Parse out_time_us or out_time from FFmpeg -progress output
  int? _parseOutTimeMicroseconds(String data) {
    final usMatch = RegExp(r'out_time_us=(\d+)').firstMatch(data);
    if (usMatch != null) {
      return int.tryParse(usMatch.group(1)!);
    }
    
    final timeMatch = RegExp(r'out_time=(\d+):(\d+):(\d+)\.(\d+)').firstMatch(data);
    if (timeMatch != null) {
      final hours = int.parse(timeMatch.group(1)!);
      final minutes = int.parse(timeMatch.group(2)!);
      final seconds = int.parse(timeMatch.group(3)!);
      final micros = int.parse(timeMatch.group(4)!.padRight(6, '0').substring(0, 6));
      return Duration(hours: hours, minutes: minutes, seconds: seconds, microseconds: micros).inMicroseconds;
    }
    
    return null;
  }

  /// Get the duration of a media file using ffprobe
  Future<Duration?> _getFileDuration(String ffmpegPath, String inputPath) async {
    try {
      final ffprobePath = ffmpegPath.replaceAll('ffmpeg', 'ffprobe');
      final result = await Process.run(ffprobePath, [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'csv=p=0',
        inputPath,
      ]);
      
      if (result.exitCode == 0) {
        final output = result.stdout.toString().trim();
        final durationSeconds = double.tryParse(output);
        if (durationSeconds != null) {
          return Duration(microseconds: (durationSeconds * 1000000).round());
        }
      }
      return null;
    } catch (e) {
      print("Could not get duration: $e");
      return null;
    }
  }

  /// Check if the input file contains an audio stream
  Future<bool> _hasAudioStream(String ffmpegPath, String inputPath) async {
    try {
      final ffprobePath = ffmpegPath.replaceAll('ffmpeg', 'ffprobe');
      final result = await Process.run(ffprobePath, [
        '-v', 'error',
        '-select_streams', 'a',
        '-show_entries', 'stream=codec_type',
        '-of', 'csv=p=0',
        inputPath,
      ]);
      
      final output = result.stdout.toString().trim();
      print("Audio stream check: '$output'");
      return output.contains('audio');
    } catch (e) {
      print("Could not check audio streams: $e");
      return true;
    }
  }

  /// Finds FFmpeg on the system PATH
  Future<String?> _findFFmpeg() async {
    try {
      if (Platform.isMacOS) {
        final paths = [
          '/opt/homebrew/bin/ffmpeg',
          '/usr/local/bin/ffmpeg',
        ];
        for (final path in paths) {
          if (await File(path).exists()) return path;
        }
      }
      
      final cmd = Platform.isWindows ? 'where' : 'which';
      final result = await Process.run(cmd, ['ffmpeg']);
      if (result.exitCode == 0) {
        final path = result.stdout.toString().trim().split('\n').first;
        if (path.isNotEmpty) return path;
      }
      return null;
    } catch (e) {
      print("Could not locate FFmpeg: $e");
      return null;
    }
  }
}