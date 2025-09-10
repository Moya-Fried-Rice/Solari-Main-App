import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'ai_assistant_screen.dart';

/// Log entry types for categorizing messages
enum LogType { system, sent, received, timing, error, image, audio }

/// Audio properties class
class AudioProperties {
  final int sampleRate;
  final int channels;
  final int bitDepth;
  final double duration;
  final String format;
  final double? compressionRatio;

  AudioProperties({
    required this.sampleRate,
    required this.channels,
    required this.bitDepth,
    required this.duration,
    required this.format,
    this.compressionRatio,
  });
}

/// Audio data wrapper class
class AudioData {
  final Uint8List data;
  final AudioProperties properties;

  AudioData({required this.data, required this.properties});
}

/// A structured log entry with metadata
class LogEntry {
  final String message;
  final LogType type;
  final DateTime timestamp;
  final int? dataSize;
  final Duration? duration;
  final Uint8List? imageData; // Add image data to log entries
  final AudioData? audioData; // Add audio data to log entries

  LogEntry({
    required this.message,
    required this.type,
    DateTime? timestamp,
    this.dataSize,
    this.duration,
    this.imageData,
    this.audioData,
  }) : timestamp = timestamp ?? DateTime.now();

  String get formattedMessage {
    final timeStr =
        '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}.'
        '${timestamp.millisecond.toString().padLeft(3, '0')}';

    String prefix = switch (type) {
      LogType.system => '[SYS]',
      LogType.sent => '[SENT]',
      LogType.received => '[RCV]',
      LogType.timing => '[TIME]',
      LogType.error => '[ERR]',
      LogType.image => '[IMG]',
      LogType.audio => '[AUD]',
    };

    String sizeInfo = dataSize != null ? ' (${dataSize}B)' : '';
    String durationInfo = duration != null
        ? ' [${duration!.inMilliseconds}ms]'
        : '';

    return '$timeStr $prefix $message$sizeInfo$durationInfo';
  }

  Color get backgroundColor {
    return switch (type) {
      LogType.system => Colors.blue[50]!,
      LogType.sent => Colors.green[50]!,
      LogType.received => Colors.orange[50]!,
      LogType.timing => Colors.purple[50]!,
      LogType.error => Colors.red[50]!,
      LogType.image => Colors.indigo[50]!,
      LogType.audio => Colors.cyan[50]!,
    };
  }

  Color get textColor {
    return switch (type) {
      LogType.system => Colors.blue[800]!,
      LogType.sent => Colors.green[800]!,
      LogType.received => Colors.orange[800]!,
      LogType.timing => Colors.purple[800]!,
      LogType.error => Colors.red[800]!,
      LogType.image => Colors.indigo[800]!,
      LogType.audio => Colors.cyan[800]!,
    };
  }
}

/// Solari Screen for BLE communication with enhanced logging and timing
class SolariScreen extends StatefulWidget {
  final BluetoothDevice device;

  const SolariScreen({super.key, required this.device});

  @override
  State<SolariScreen> createState() => _SolariScreenState();
}

class _SolariScreenState extends State<SolariScreen> {
  // Connection and subscription management
  late StreamSubscription<BluetoothConnectionState>
  _connectionStateSubscription;
  late StreamSubscription<int> _mtuSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  BluetoothCharacteristic? _targetCharacteristic;

  // UI Controllers
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // State management
  final List<LogEntry> _logEntries = [];
  bool _isConnected = false;
  bool _isSubscribed = false;
  int _currentMtu = 23; // Default BLE MTU
  bool _autoScrollEnabled = true; // Track if auto-scroll should happen

  // Echo detection
  List<int>? _lastSentData;
  DateTime? _lastSentTime;

  // Image reception state
  bool _receivingImage = false;
  int _expectedImageSize = 0;
  final List<int> _imageBuffer = [];
  Uint8List? _currentImage;
  DateTime? _imageStartTime;

  // Audio reception state
  bool _receivingAudio = false;
  int _expectedAudioSize = 0;
  final List<int> _audioBuffer = [];
  DateTime? _audioStartTime;

  // Timing and performance metrics
  final Map<String, DateTime> _operationStartTimes = {};
  final Map<String, Duration> _operationDurations = {};
  int _messageCount = 0;
  int _totalBytesReceived = 0;
  int _totalBytesSent = 0;

  // Audio player
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isAudioPlaying = false;
  StreamSubscription<PlayerState>? _audioPlayerStateSubscription;

  // Configuration constants
  static const String kTargetCharacteristicUUID =
      "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  static const int kMaxEchoDetectionWindow = 1000; // milliseconds
  static const int kRequestedMtu = 512;
  static const int kBleOverhead = 3;

  @override
  void initState() {
    super.initState();
    _startOperation('initialization');

    // Setup audio player state listener
    _audioPlayerStateSubscription = _audioPlayer.onPlayerStateChanged.listen((state) {
      setState(() {
        _isAudioPlaying = state == PlayerState.playing;
      });
    });

    // Add scroll listener to detect manual scrolling
    _scrollController.addListener(() {
      if (_scrollController.hasClients) {
        final position = _scrollController.position;
        // Only disable auto-scroll if user scrolls significantly away from bottom
        if (position.pixels < position.maxScrollExtent - 200) {
          _autoScrollEnabled = false;
        } else if (position.pixels >= position.maxScrollExtent - 50) {
          // Re-enable when back near bottom
          _autoScrollEnabled = true;
        }
      }
    });

    _connectionStateSubscription = widget.device.connectionState.listen((
      state,
    ) {
      final wasConnected = _isConnected;
      setState(() {
        _isConnected = state == BluetoothConnectionState.connected;
      });

      if (!wasConnected && _isConnected) {
        _addLog('Device connected successfully', LogType.system);
      } else if (wasConnected && !_isConnected) {
        _addLog('Device disconnected', LogType.system);
      }

      if (state == BluetoothConnectionState.disconnected) {
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    });

    // Listen to MTU changes with timing
    _mtuSubscription = widget.device.mtu.listen((mtu) {
      setState(() {
        _currentMtu = mtu;
      });
      _addLog('MTU changed to: $mtu bytes', LogType.system);
    });

    _initializeBle();
    _endOperation('initialization');
  }

  @override
  void dispose() {
    _connectionStateSubscription.cancel();
    _mtuSubscription.cancel();
    _notificationSubscription?.cancel();
    _audioPlayerStateSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  /// Auto-scroll to bottom of the log
  void _scrollToBottom() {
    _autoScrollEnabled =
        true; // Re-enable auto-scroll when manually scrolling to bottom
    if (_scrollController.hasClients) {
      // Use multiple post-frame callbacks to ensure images are rendered
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOut,
          );

          // Add a second callback to handle image rendering delays
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              );
            }
          });
        }
      });
    }
  }

  /// Consistently auto-scroll to bottom with better timing
  void _autoScrollToBottom() {
    if (_autoScrollEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );

          // Additional scroll for images that might still be loading
          Future.delayed(const Duration(milliseconds: 100), () {
            if (_scrollController.hasClients) {
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              );
            }
          });
        }
      });
    }
  }

  /// Start timing an operation
  void _startOperation(String operationName) {
    _operationStartTimes[operationName] = DateTime.now();
  }

  /// End timing an operation and log the duration
  void _endOperation(String operationName) {
    final startTime = _operationStartTimes[operationName];
    if (startTime != null) {
      final duration = DateTime.now().difference(startTime);
      _operationDurations[operationName] = duration;
      _addLog('$operationName completed', LogType.timing, duration: duration);
      _operationStartTimes.remove(operationName);
    }
  }

  /// Add a structured log entry
  void _addLog(
    String message,
    LogType type, {
    int? dataSize,
    Duration? duration,
    Uint8List? imageData,
    AudioData? audioData,
  }) {
    final entry = LogEntry(
      message: message,
      type: type,
      dataSize: dataSize,
      duration: duration,
      imageData: imageData,
      audioData: audioData,
    );

    setState(() {
      _logEntries.add(entry);
      if (type == LogType.received) {
        _messageCount++;
        _totalBytesReceived += dataSize ?? 0;
      } else if (type == LogType.sent) {
        _totalBytesSent += dataSize ?? 0;
      }
    });

    // Use improved auto-scroll mechanism
    _autoScrollToBottom();
  }

  /// Initialize BLE with comprehensive timing
  Future<void> _initializeBle() async {
    _startOperation('ble_setup');

    try {
      await _discoverAndConfigureCharacteristic();
      await _requestOptimalMtu();
      _endOperation('ble_setup');
    } catch (e) {
      _addLog('BLE initialization failed: $e', LogType.error);
      _endOperation('ble_setup');
    }
  }

  /// Discover services and configure the target characteristic
  Future<void> _discoverAndConfigureCharacteristic() async {
    _startOperation('characteristic_discovery');

    try {
      _addLog('Starting service discovery', LogType.system);
      final services = await widget.device.discoverServices();

      for (final service in services) {
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid.str.toLowerCase() ==
              kTargetCharacteristicUUID.toLowerCase()) {
            setState(() {
              _targetCharacteristic = characteristic;
            });

            _addLog('Target characteristic found!', LogType.system);

            // Auto-subscribe to notifications if supported
            if (characteristic.properties.notify) {
              await _subscribeToNotifications();
            }

            _endOperation('characteristic_discovery');
            return;
          }
        }
      }

      _addLog('Target characteristic not found!', LogType.error);
      _endOperation('characteristic_discovery');
    } catch (e) {
      _addLog('Error during characteristic discovery: $e', LogType.error);
      _endOperation('characteristic_discovery');
    }
  }

  /// Request optimal MTU with comprehensive logging
  Future<void> _requestOptimalMtu() async {
    if (_targetCharacteristic == null) {
      _addLog('Cannot request MTU: characteristic not ready', LogType.error);
      return;
    }

    _startOperation('mtu_negotiation');

    try {
      _addLog('Requesting MTU: $kRequestedMtu bytes', LogType.system);
      final negotiatedMtu = await widget.device.requestMtu(kRequestedMtu);

      setState(() {
        _currentMtu = negotiatedMtu;
      });

      _addLog(
        'MTU negotiated: $negotiatedMtu bytes (requested: $kRequestedMtu)',
        LogType.system,
      );

      // Notify device of negotiated MTU
      await _notifyDeviceOfMtu(negotiatedMtu);
      _endOperation('mtu_negotiation');
    } catch (e) {
      _addLog('MTU negotiation failed: $e', LogType.error);
      _endOperation('mtu_negotiation');
    }
  }

  /// Notify the device of the negotiated MTU
  Future<void> _notifyDeviceOfMtu(int mtu) async {
    if (_targetCharacteristic == null) return;

    try {
      final mtuMessage = utf8.encode("MTU:$mtu");
      _lastSentData = List.from(mtuMessage);
      _lastSentTime = DateTime.now();

      await _targetCharacteristic!.write(
        mtuMessage,
        withoutResponse: _targetCharacteristic!.properties.writeWithoutResponse,
      );

      _addLog(
        'MTU info sent to device',
        LogType.sent,
        dataSize: mtuMessage.length,
      );
    } catch (e) {
      _addLog('Failed to notify device of MTU: $e', LogType.error);
      _lastSentData = null;
      _lastSentTime = null;
    }
  }

  /// Analyze image properties from raw bytes
  Future<Map<String, dynamic>> _analyzeImageProperties(
    Uint8List imageData,
  ) async {
    final properties = <String, dynamic>{
      'size_bytes': imageData.length,
      'format': 'Unknown',
      'width': null,
      'height': null,
      'compression': 'Unknown',
    };

    try {
      // Detect image format by examining file headers
      if (imageData.length >= 8) {
        // PNG signature
        if (imageData[0] == 0x89 &&
            imageData[1] == 0x50 &&
            imageData[2] == 0x4E &&
            imageData[3] == 0x47) {
          properties['format'] = 'PNG';

          // PNG dimensions are at bytes 16-23 (after 8-byte signature + 4-byte length + 4-byte IHDR)
          if (imageData.length >= 24) {
            properties['width'] =
                (imageData[16] << 24) |
                (imageData[17] << 16) |
                (imageData[18] << 8) |
                imageData[19];
            properties['height'] =
                (imageData[20] << 24) |
                (imageData[21] << 16) |
                (imageData[22] << 8) |
                imageData[23];
          }
        }
        // JPEG signature
        else if (imageData[0] == 0xFF && imageData[1] == 0xD8) {
          properties['format'] = 'JPEG';
          properties['compression'] = 'Lossy';

          // Parse JPEG for dimensions (simplified)
          for (int i = 2; i < imageData.length - 8; i++) {
            if (imageData[i] == 0xFF &&
                (imageData[i + 1] == 0xC0 || imageData[i + 1] == 0xC2)) {
              if (i + 7 < imageData.length) {
                properties['height'] =
                    (imageData[i + 5] << 8) | imageData[i + 6];
                properties['width'] =
                    (imageData[i + 7] << 8) | imageData[i + 8];
                break;
              }
            }
          }
        }
        // BMP signature
        else if (imageData[0] == 0x42 && imageData[1] == 0x4D) {
          properties['format'] = 'BMP';
          properties['compression'] = 'Uncompressed';

          if (imageData.length >= 26) {
            properties['width'] =
                (imageData[21] << 24) |
                (imageData[20] << 16) |
                (imageData[19] << 8) |
                imageData[18];
            properties['height'] =
                (imageData[25] << 24) |
                (imageData[24] << 16) |
                (imageData[23] << 8) |
                imageData[22];
          }
        }
        // GIF signature
        else if (imageData.length >= 6 &&
            imageData[0] == 0x47 &&
            imageData[1] == 0x49 &&
            imageData[2] == 0x46) {
          properties['format'] = 'GIF';
          properties['compression'] = 'Lossless';

          if (imageData.length >= 10) {
            properties['width'] = imageData[6] | (imageData[7] << 8);
            properties['height'] = imageData[8] | (imageData[9] << 8);
          }
        }
        // WebP signature
        else if (imageData.length >= 12 &&
            imageData[0] == 0x52 &&
            imageData[1] == 0x49 &&
            imageData[2] == 0x46 &&
            imageData[3] == 0x46 &&
            imageData[8] == 0x57 &&
            imageData[9] == 0x45 &&
            imageData[10] == 0x42 &&
            imageData[11] == 0x50) {
          properties['format'] = 'WebP';
          properties['compression'] = 'Variable';
        }
      }

      // Calculate additional properties
      if (properties['width'] != null && properties['height'] != null) {
        final width = properties['width'] as int;
        final height = properties['height'] as int;
        properties['aspect_ratio'] = (width / height).toStringAsFixed(2);
        properties['total_pixels'] = width * height;

        // Estimate bits per pixel
        if (properties['size_bytes'] != null) {
          final bpp = (properties['size_bytes'] as int) * 8 / (width * height);
          properties['bits_per_pixel'] = bpp.toStringAsFixed(1);
        }
      }
    } catch (e) {
      properties['error'] = 'Failed to analyze: $e';
    }

    return properties;
  }

  /// Analyze audio properties from raw WAV bytes
  Future<Map<String, dynamic>> _analyzeAudioProperties(
    Uint8List audioData,
  ) async {
    final properties = <String, dynamic>{
      'size_bytes': audioData.length,
      'format': 'Unknown',
      'sample_rate': null,
      'channels': null,
      'bit_depth': null,
      'duration_seconds': null,
      'data_rate': null,
    };

    try {
      // Check for WAV file signature
      if (audioData.length >= 44 &&
          audioData[0] == 0x52 && // 'R'
          audioData[1] == 0x49 && // 'I'
          audioData[2] == 0x46 && // 'F'
          audioData[3] == 0x46 && // 'F'
          audioData[8] == 0x57 && // 'W'
          audioData[9] == 0x41 && // 'A'
          audioData[10] == 0x56 && // 'V'
          audioData[11] == 0x45) {
        // 'E'

        properties['format'] = 'WAV';

        // Find 'fmt ' chunk (usually starts at byte 12)
        int fmtIndex = -1;
        for (int i = 12; i < audioData.length - 4; i++) {
          if (audioData[i] == 0x66 && // 'f'
              audioData[i + 1] == 0x6D && // 'm'
              audioData[i + 2] == 0x74 && // 't'
              audioData[i + 3] == 0x20) {
            // ' '
            fmtIndex = i;
            break;
          }
        }

        if (fmtIndex >= 0 && fmtIndex + 24 < audioData.length) {
          // Skip 'fmt ' and chunk size (8 bytes)
          final headerStart = fmtIndex + 8;

          // Audio format (2 bytes) - should be 1 for PCM
          final audioFormat =
              (audioData[headerStart + 1] << 8) | audioData[headerStart];

          // Number of channels (2 bytes)
          final numChannels =
              (audioData[headerStart + 3] << 8) | audioData[headerStart + 2];
          properties['channels'] = numChannels;

          // Sample rate (4 bytes)
          final sampleRate =
              (audioData[headerStart + 7] << 24) |
              (audioData[headerStart + 6] << 16) |
              (audioData[headerStart + 5] << 8) |
              audioData[headerStart + 4];
          properties['sample_rate'] = sampleRate;

          // Byte rate (4 bytes)
          final byteRate =
              (audioData[headerStart + 11] << 24) |
              (audioData[headerStart + 10] << 16) |
              (audioData[headerStart + 9] << 8) |
              audioData[headerStart + 8];

          // Bits per sample (2 bytes)
          final bitsPerSample =
              (audioData[headerStart + 15] << 8) | audioData[headerStart + 14];
          properties['bit_depth'] = bitsPerSample;

          // Calculate duration and data rate
          if (sampleRate > 0 && numChannels > 0 && bitsPerSample > 0) {
            // Find 'data' chunk to get actual audio data size
            int dataIndex = -1;
            int dataSize = 0;

            for (int i = headerStart + 16; i < audioData.length - 8; i++) {
              if (audioData[i] == 0x64 && // 'd'
                  audioData[i + 1] == 0x61 && // 'a'
                  audioData[i + 2] == 0x74 && // 't'
                  audioData[i + 3] == 0x61) {
                // 'a'
                dataIndex = i;
                // Data chunk size (4 bytes after 'data')
                dataSize =
                    (audioData[i + 7] << 24) |
                    (audioData[i + 6] << 16) |
                    (audioData[i + 5] << 8) |
                    audioData[i + 4];
                break;
              }
            }

            if (dataIndex >= 0) {
              final bytesPerSample = bitsPerSample ~/ 8;
              final totalSamples = dataSize ~/ (numChannels * bytesPerSample);
              final durationSeconds = totalSamples / sampleRate;

              properties['duration_seconds'] = durationSeconds.toStringAsFixed(
                2,
              );
              properties['data_rate'] =
                  '${(byteRate / 1024).toStringAsFixed(1)} KB/s';

              // Audio quality assessment
              if (sampleRate >= 44100 && bitsPerSample >= 16) {
                properties['quality'] = 'High';
              } else if (sampleRate >= 22050 && bitsPerSample >= 8) {
                properties['quality'] = 'Medium';
              } else {
                properties['quality'] = 'Low';
              }
            }
          }

          // Audio format description
          if (audioFormat == 1) {
            properties['encoding'] = 'PCM (Uncompressed)';
          } else {
            properties['encoding'] = 'Compressed (Format: $audioFormat)';
          }
        }
      }
      // Check for other audio formats
      else if (audioData.length >= 4) {
        // MP3 signature
        if ((audioData[0] == 0xFF && (audioData[1] & 0xE0) == 0xE0) ||
            (audioData[0] == 0x49 &&
                audioData[1] == 0x44 &&
                audioData[2] == 0x33)) {
          properties['format'] = 'MP3';
          properties['encoding'] = 'MPEG Audio Layer 3';
        }
        // OGG Vorbis signature
        else if (audioData[0] == 0x4F &&
            audioData[1] == 0x67 &&
            audioData[2] == 0x67 &&
            audioData[3] == 0x53) {
          properties['format'] = 'OGG';
          properties['encoding'] = 'Ogg Vorbis';
        }
        // FLAC signature
        else if (audioData.length >= 4 &&
            audioData[0] == 0x66 &&
            audioData[1] == 0x4C &&
            audioData[2] == 0x61 &&
            audioData[3] == 0x43) {
          properties['format'] = 'FLAC';
          properties['encoding'] = 'Free Lossless Audio Codec';
        }
      }

      // Calculate compression ratio if applicable
      if (properties['sample_rate'] != null &&
          properties['channels'] != null &&
          properties['bit_depth'] != null &&
          properties['duration_seconds'] != null) {
        final sampleRate = properties['sample_rate'] as int;
        final channels = properties['channels'] as int;
        final bitDepth = properties['bit_depth'] as int;
        final duration = double.parse(properties['duration_seconds'] as String);

        final uncompressedSize =
            (sampleRate * channels * bitDepth * duration / 8).round();
        final compressionRatio = uncompressedSize / audioData.length;

        if (compressionRatio > 1.1) {
          properties['compression_ratio'] =
              '${compressionRatio.toStringAsFixed(1)}:1';
        } else {
          properties['compression_ratio'] = 'Uncompressed';
        }
      }
    } catch (e) {
      properties['error'] = 'Failed to analyze: $e';
    }

    return properties;
  }

  /// Play audio data from AudioData object
  Future<void> _playAudioData(AudioData audioData) async {
    try {
      _addLog('Playing audio...', LogType.audio);

      // Use BytesSource to play audio from memory
      await _audioPlayer.play(BytesSource(audioData.data));

      _addLog('Audio playback started successfully', LogType.audio);
    } catch (e) {
      _addLog('Failed to play audio: $e', LogType.error);
    }
  }

  /// Check if two byte lists are equal (for echo detection)
  bool _areListsEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Create a truncated representation of binary data for logging
  String _truncateBinaryData(List<int> data, {int maxBytes = 8}) {
    if (data.isEmpty) return '[]';

    final truncated = data.take(maxBytes).toList();
    final hexBytes = truncated
        .map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}')
        .join(', ');

    if (data.length > maxBytes) {
      return '[$hexBytes...] (${data.length} bytes total)';
    } else {
      return '[$hexBytes] (${data.length} bytes)';
    }
  }

  /// Process incoming image data with enhanced logging
  void _processImageData(List<int> value) {
    // Don't start timing operation for every chunk to avoid spam
    // _startOperation('image_processing');

    // Check if data could be a text command
    bool isTextCommand = false;
    String dataStr = '';

    // Only decode as UTF-8 if it looks like text (all bytes < 128)
    if (value.every((byte) => byte < 128)) {
      try {
        dataStr = utf8.decode(value);
        isTextCommand = true;
      } catch (e) {
        isTextCommand = false;
      }
    }

    // Handle text commands
    if (isTextCommand) {
      if (dataStr.startsWith('IMG_START:')) {
        final sizeStr = dataStr.substring(10);
        try {
          _expectedImageSize = int.parse(sizeStr);
          _receivingImage = true;
          _imageBuffer.clear();
          _imageStartTime = DateTime.now();

          _addLog(
            'Starting image reception: $_expectedImageSize bytes',
            LogType.image,
          );
        } catch (e) {
          _addLog('Invalid image size: $sizeStr', LogType.error);
        }
        // _endOperation('image_processing');
        return;
      }

      if (dataStr == 'IMG_END') {
        if (_receivingImage) {
          _addLog('Received IMG_END signal', LogType.image);
          _finishImageReception();
        }
        // _endOperation('image_processing');
        return;
      }
    }

    // Add data to image buffer if receiving
    if (_receivingImage) {
      _imageBuffer.addAll(value);
      // Progress will be shown in the progress bar widget, not in logs
      setState(() {}); // Trigger UI update for progress bar
      _autoScrollToBottom(); // Auto-scroll for progress updates
    }

    // _endOperation('image_processing');
  }

  /// Process incoming audio data with enhanced logging
  void _processAudioData(List<int> value) {
    // Check if data could be a text command
    bool isTextCommand = false;
    String dataStr = '';

    // Only decode as UTF-8 if it looks like text (all bytes < 128)
    if (value.every((byte) => byte < 128)) {
      try {
        dataStr = utf8.decode(value);
        isTextCommand = true;
      } catch (e) {
        isTextCommand = false;
      }
    }

    // Handle text commands
    if (isTextCommand) {
      if (dataStr.startsWith('AUD_START:')) {
        final sizeStr = dataStr.substring(10);
        try {
          _expectedAudioSize = int.parse(sizeStr);
          _receivingAudio = true;
          _audioBuffer.clear();
          _audioStartTime = DateTime.now();

          _addLog(
            'Starting audio reception: $_expectedAudioSize bytes',
            LogType.audio,
          );
        } catch (e) {
          _addLog('Invalid audio size: $sizeStr', LogType.error);
        }
        return;
      }

      if (dataStr == 'AUD_END') {
        if (_receivingAudio) {
          _addLog('Received AUD_END signal', LogType.audio);
          _finishAudioReception();
        }
        return;
      }
    }

    // Add data to audio buffer if receiving
    if (_receivingAudio) {
      _audioBuffer.addAll(value);
      // Progress will be shown in the progress bar widget, not in logs
      setState(() {}); // Trigger UI update for progress bar
      _autoScrollToBottom(); // Auto-scroll for progress updates
    }
  }

  /// Finish audio reception with timing information
  void _finishAudioReception() {
    _startOperation('audio_finalization');

    try {
      final actualSize = _audioBuffer.length;
      final transferDuration = _audioStartTime != null
          ? DateTime.now().difference(_audioStartTime!)
          : null;

      final audioData = Uint8List.fromList(_audioBuffer);
      setState(() {
        _receivingAudio = false;
      });

      final sizeInfo = actualSize == _expectedAudioSize
          ? 'Size: ${actualSize}B'
          : 'Size: ${actualSize}B (expected: $_expectedAudioSize)';

      final speedInfo = transferDuration != null && actualSize > 0
          ? ' - Speed: ${(actualSize / transferDuration.inMilliseconds * 1000 / 1024).toStringAsFixed(2)} KB/s'
          : '';

      // Analyze audio properties
      _analyzeAudioProperties(audioData)
          .then((properties) {
            String propertiesInfo = '';
            AudioProperties audioProperties;

            if (properties['format'] != 'Unknown') {
              propertiesInfo = ' | Format: ${properties['format']}';

              if (properties['sample_rate'] != null) {
                propertiesInfo +=
                    ' | Sample Rate: ${properties['sample_rate']} Hz';
              }

              if (properties['channels'] != null) {
                propertiesInfo += ' | Channels: ${properties['channels']}';
              }

              if (properties['bit_depth'] != null) {
                propertiesInfo += ' | Bit Depth: ${properties['bit_depth']}';
              }

              if (properties['duration_seconds'] != null) {
                propertiesInfo +=
                    ' | Duration: ${properties['duration_seconds']}s';
              }

              if (properties['encoding'] != null) {
                propertiesInfo += ' | Encoding: ${properties['encoding']}';
              }

              if (properties['quality'] != null) {
                propertiesInfo += ' | Quality: ${properties['quality']}';
              }

              if (properties['compression_ratio'] != null) {
                propertiesInfo +=
                    ' | Compression: ${properties['compression_ratio']}';
              }

              audioProperties = AudioProperties(
                sampleRate: properties['sample_rate'] ?? 0,
                channels: properties['channels'] ?? 1,
                bitDepth: properties['bit_depth'] ?? 16,
                duration: (properties['duration_seconds'] ?? 0.0).toDouble(),
                format: properties['format'] ?? 'Unknown',
                compressionRatio: properties['compression_ratio']?.toDouble(),
              );
            } else {
              // Default properties if analysis failed
              audioProperties = AudioProperties(
                sampleRate: 44100,
                channels: 1,
                bitDepth: 16,
                duration: 0.0,
                format: 'Unknown',
              );
            }

            final audioDataObj = AudioData(
              data: audioData,
              properties: audioProperties,
            );

            _addLog(
              'Audio received! $sizeInfo$speedInfo$propertiesInfo',
              LogType.audio,
              dataSize: actualSize,
              duration: transferDuration,
              audioData: audioDataObj,
            );
          })
          .catchError((error) {
            // Fallback if audio analysis fails - create default AudioData
            final defaultProperties = AudioProperties(
              sampleRate: 44100,
              channels: 1,
              bitDepth: 16,
              duration: 0.0,
              format: 'Unknown',
            );

            final audioDataObj = AudioData(
              data: audioData,
              properties: defaultProperties,
            );

            _addLog(
              'Audio received! $sizeInfo$speedInfo | Analysis failed: $error',
              LogType.audio,
              dataSize: actualSize,
              duration: transferDuration,
              audioData: audioDataObj,
            );
          });
    } catch (e) {
      _addLog('Failed to process audio: $e', LogType.error);
      setState(() {
        _receivingAudio = false;
      });
    }

    _endOperation('audio_finalization');
  }

  /// Finish image reception with timing information
  void _finishImageReception() {
    _startOperation('image_finalization');

    try {
      final actualSize = _imageBuffer.length;
      final transferDuration = _imageStartTime != null
          ? DateTime.now().difference(_imageStartTime!)
          : null;

      final imageData = Uint8List.fromList(_imageBuffer);
      setState(() {
        _currentImage = imageData;
        _receivingImage = false;
      });

      final sizeInfo = actualSize == _expectedImageSize
          ? 'Size: ${actualSize}B'
          : 'Size: ${actualSize}B (expected: $_expectedImageSize)';

      final speedInfo = transferDuration != null && actualSize > 0
          ? ' - Speed: ${(actualSize / transferDuration.inMilliseconds * 1000 / 1024).toStringAsFixed(2)} KB/s'
          : '';

      // Analyze image properties
      _analyzeImageProperties(imageData)
          .then((properties) {
            String propertiesInfo = '';
            if (properties['format'] != 'Unknown') {
              propertiesInfo = ' | Format: ${properties['format']}';

              if (properties['width'] != null && properties['height'] != null) {
                propertiesInfo +=
                    ' | Dimensions: ${properties['width']}x${properties['height']}';
                propertiesInfo += ' | Aspect: ${properties['aspect_ratio']}';
              }

              if (properties['compression'] != 'Unknown') {
                propertiesInfo +=
                    ' | Compression: ${properties['compression']}';
              }

              if (properties['bits_per_pixel'] != null) {
                propertiesInfo += ' | BPP: ${properties['bits_per_pixel']}';
              }

              if (properties['total_pixels'] != null) {
                propertiesInfo += ' | Pixels: ${properties['total_pixels']}';
              }
            }

            _addLog(
              'Image received! $sizeInfo$speedInfo$propertiesInfo',
              LogType.image,
              dataSize: actualSize,
              duration: transferDuration,
              imageData: imageData,
            );
          })
          .catchError((error) {
            // Fallback if image analysis fails
            _addLog(
              'Image received! $sizeInfo$speedInfo | Analysis failed: $error',
              LogType.image,
              dataSize: actualSize,
              duration: transferDuration,
              imageData: imageData,
            );
          });
    } catch (e) {
      _addLog('Failed to process image: $e', LogType.error);
      setState(() {
        _receivingImage = false;
      });
    }

    _endOperation('image_finalization');
  }

  /// Enable notifications on the target characteristic
  Future<void> _enableNotifications() async {
    if (_targetCharacteristic == null) return;

    _startOperation('enable_notifications');
    try {
      await _targetCharacteristic!.setNotifyValue(true);
      _addLog('Notifications enabled successfully', LogType.system);
      _endOperation('enable_notifications');
    } catch (e) {
      _addLog('Failed to enable notifications: $e', LogType.error);
      _endOperation('enable_notifications');
      rethrow;
    }
  }

  /// Listen to characteristic notifications with enhanced echo detection
  Future<void> _listenToNotifications() async {
    if (_targetCharacteristic == null) return;

    _startOperation('notification_setup');
    try {
      _notificationSubscription = _targetCharacteristic!.lastValueStream.listen(
        (value) {
          final receiveTime = DateTime.now();

          // Enhanced echo detection
          bool isEcho = false;
          if (_lastSentData != null && _lastSentTime != null) {
            final timeSinceSent = receiveTime
                .difference(_lastSentTime!)
                .inMilliseconds;
            if (_areListsEqual(value, _lastSentData!) &&
                timeSinceSent < kMaxEchoDetectionWindow) {
              isEcho = true;
              _addLog(
                'Echo detected (${timeSinceSent}ms delay)',
                LogType.timing,
                dataSize: value.length,
              );
            }
          }

          if (!isEcho) {
            // Skip logging individual chunks during image or audio transfer
            if (!_receivingImage && !_receivingAudio) {
              String notification;
              try {
                notification = utf8.decode(value);
              } catch (e) {
                // Show truncated binary data in RCV log
                notification = 'Binary data: ${_truncateBinaryData(value)}';
              }

              _addLog(notification, LogType.received, dataSize: value.length);
            }

            // Process both image and audio data
            _processImageData(value);
            _processAudioData(value);
          }
        },
      );

      setState(() {
        _isSubscribed = true;
      });

      _addLog('Notification listener started', LogType.system);
      _endOperation('notification_setup');
    } catch (e) {
      _addLog('Failed to setup notification listener: $e', LogType.error);
      _endOperation('notification_setup');
    }
  }

  /// Subscribe to notifications with comprehensive error handling
  Future<void> _subscribeToNotifications() async {
    if (_targetCharacteristic == null) return;

    try {
      await _enableNotifications();
      await _listenToNotifications();
      _addLog('Successfully subscribed to notifications', LogType.system);
    } catch (e) {
      _addLog('Subscription failed: $e', LogType.error);
    }
  }

  /// Disable notifications
  Future<void> _disableNotifications() async {
    if (_targetCharacteristic == null) return;

    try {
      await _targetCharacteristic!.setNotifyValue(false);
      _addLog('Notifications disabled', LogType.system);
    } catch (e) {
      _addLog('Failed to disable notifications: $e', LogType.error);
      rethrow;
    }
  }

  /// Stop listening to notifications
  Future<void> _stopListeningToNotifications() async {
    try {
      _notificationSubscription?.cancel();
      _notificationSubscription = null;

      setState(() {
        _isSubscribed = false;
      });
      _addLog('Stopped listening to notifications', LogType.system);
    } catch (e) {
      _addLog('Failed to stop notification listener: $e', LogType.error);
    }
  }

  /// Unsubscribe from notifications
  Future<void> _unsubscribeFromNotifications() async {
    if (_targetCharacteristic == null) return;

    try {
      await _disableNotifications();
      await _stopListeningToNotifications();
      _addLog('Successfully unsubscribed from notifications', LogType.system);
    } catch (e) {
      _addLog('Unsubscription failed: $e', LogType.error);
    }
  }

  /// Send message with comprehensive timing and validation
  Future<void> _sendMessage() async {
    if (_targetCharacteristic == null) {
      _addLog('Cannot send: characteristic not ready', LogType.error);
      return;
    }

    final message = _messageController.text.trim();
    if (message.isEmpty) return;

    _startOperation('message_send');

    try {
      final data = utf8.encode(message);
      final maxDataSize = _currentMtu - kBleOverhead;

      if (data.length > maxDataSize) {
        _addLog(
          'Message too long! Max: ${maxDataSize}B, Message: ${data.length}B',
          LogType.error,
        );
        _endOperation('message_send');
        return;
      }

      // Track message for echo detection
      _lastSentData = List.from(data);
      _lastSentTime = DateTime.now();

      await _targetCharacteristic!.write(
        data,
        withoutResponse: _targetCharacteristic!.properties.writeWithoutResponse,
      );

      _addLog(message, LogType.sent, dataSize: data.length);
      _messageController.clear();
      _endOperation('message_send');
    } catch (e) {
      _addLog('Send failed: $e', LogType.error);
      _lastSentData = null;
      _lastSentTime = null;
      _endOperation('message_send');
    }
  }

  /// Get performance statistics
  String get _performanceStats {
    final avgResponseTime = _operationDurations.isNotEmpty
        ? _operationDurations.values
                  .map((d) => d.inMilliseconds)
                  .reduce((a, b) => a + b) /
              _operationDurations.length
        : 0.0;

    return 'Messages: $_messageCount | '
        'RX: ${(_totalBytesReceived / 1024).toStringAsFixed(1)}KB | '
        'TX: ${(_totalBytesSent / 1024).toStringAsFixed(1)}KB | '
        'Avg: ${avgResponseTime.toStringAsFixed(1)}ms';
  }

  /// Get current image transfer progress (0.0 to 1.0)
  double get _imageProgress {
    if (!_receivingImage || _expectedImageSize <= 0) return 0.0;
    return (_imageBuffer.length / _expectedImageSize).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Solari Console', style: TextStyle(fontSize: 14)),
        backgroundColor: _isConnected ? Colors.green[100] : Colors.red[100],
        automaticallyImplyLeading: false,
        actions: [
          // Static Auto-Scroll Button
          IconButton(
            onPressed: _scrollToBottom,
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            tooltip: 'Scroll to bottom',
            padding: const EdgeInsets.all(8),
          ),
          // AI Assistant Button
          IconButton(
            onPressed: _isConnected
                ? () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            AIAssistantScreen(device: widget.device),
                      ),
                    );
                  }
                : null,
            icon: const Icon(Icons.smart_toy, size: 20),
            tooltip: 'AI Assistant',
            padding: const EdgeInsets.all(8),
            color: _isConnected ? Colors.black : Colors.grey,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (value) {
              switch (value) {
                case 'subscribe':
                  if (_isSubscribed) {
                    _unsubscribeFromNotifications();
                  } else {
                    _subscribeToNotifications();
                  }
                  break;
                case 'clear_image':
                  setState(() => _currentImage = null);
                  break;
                case 'clear_logs':
                  setState(() => _logEntries.clear());
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'subscribe',
                enabled: _targetCharacteristic != null && _isConnected,
                child: Row(
                  children: [
                    Icon(
                      _isSubscribed
                          ? Icons.notifications_off
                          : Icons.notifications,
                      size: 16,
                      color: _isSubscribed ? Colors.orange : Colors.green,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isSubscribed ? 'Unsubscribe' : 'Subscribe',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (_currentImage != null)
                const PopupMenuItem(
                  value: 'clear_image',
                  child: Row(
                    children: [
                      Icon(
                        Icons.image_not_supported,
                        size: 16,
                        color: Colors.red,
                      ),
                      SizedBox(width: 8),
                      Text('Clear Image', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              const PopupMenuItem(
                value: 'clear_logs',
                child: Row(
                  children: [
                    Icon(Icons.clear_all, size: 16, color: Colors.blue),
                    SizedBox(width: 8),
                    Text('Clear Logs', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Status Information',
                      style: TextStyle(fontSize: 9, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Device: ${widget.device.platformName}',
                      style: const TextStyle(fontSize: 9),
                    ),
                    Text(
                      'Status: ${_isConnected ? "Connected" : "Disconnected"}',
                      style: TextStyle(
                        fontSize: 9,
                        color: _isConnected ? Colors.green : Colors.red,
                      ),
                    ),
                    Text(
                      'Characteristic: ${_targetCharacteristic != null ? "Found" : "Not Found"}',
                      style: const TextStyle(fontSize: 9),
                    ),
                    Text(
                      'MTU: $_currentMtu bytes',
                      style: const TextStyle(fontSize: 9),
                    ),
                    Text(
                      'Notifications: ${_isSubscribed ? "ON" : "OFF"}',
                      style: TextStyle(
                        fontSize: 9,
                        color: _isSubscribed ? Colors.green : Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _performanceStats,
                      style: const TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Enhanced Log Display with Inline Images
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(6),
              decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _logEntries.length + (_receivingImage ? 1 : 0),
                itemBuilder: (context, index) {
                  // Show progress bar as the last item when receiving image
                  if (_receivingImage && index == _logEntries.length) {
                    final percentage = (_imageProgress * 100).toStringAsFixed(
                      1,
                    );
                    final progressText =
                        '$percentage% (${_imageBuffer.length}/${_expectedImageSize} bytes)';
                    final now = DateTime.now();
                    final timeStr =
                        '${now.hour.toString().padLeft(2, '0')}:'
                        '${now.minute.toString().padLeft(2, '0')}:'
                        '${now.second.toString().padLeft(2, '0')}.'
                        '${now.millisecond.toString().padLeft(3, '0')}';

                    return Container(
                      margin: const EdgeInsets.symmetric(
                        vertical: 1,
                        horizontal: 4,
                      ),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.blue[50],
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: Colors.blue.withOpacity(0.3),
                          width: 0.5,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header with timestamp like other log entries
                          Text(
                            '$timeStr [PROGRESS] Receiving image... $progressText',
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue[800],
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(height: 4),
                          LinearProgressIndicator(
                            value: _imageProgress,
                            backgroundColor: Colors.blue[100],
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.blue[600]!,
                            ),
                            minHeight: 3,
                          ),
                        ],
                      ),
                    );
                  }

                  final entry = _logEntries[index];
                  return Container(
                    margin: const EdgeInsets.symmetric(
                      vertical: 1,
                      horizontal: 4,
                    ),
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: entry.backgroundColor,
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(
                        color: entry.textColor.withOpacity(0.3),
                        width: 0.5,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.formattedMessage,
                          style: TextStyle(
                            fontSize: 8,
                            color: entry.textColor,
                            fontFamily: 'monospace',
                          ),
                        ),
                        // Show image inline if this log entry contains image data
                        if (entry.imageData != null)
                          Container(
                            margin: const EdgeInsets.only(top: 4),
                            width: double.infinity,
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade400),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.memory(
                                entry.imageData!,
                                width: double.infinity,
                                fit: BoxFit.fitWidth,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    color: Colors.grey.shade100,
                                    height: 60,
                                    child: const Center(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.error,
                                            color: Colors.red,
                                            size: 12,
                                          ),
                                          SizedBox(height: 2),
                                          Text(
                                            'Invalid image',
                                            style: TextStyle(fontSize: 8),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        // Show audio controls inline if this log entry contains audio data
                        if (entry.audioData != null)
                          Container(
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.cyan.withOpacity(0.1),
                              border: Border.all(
                                color: Colors.cyan.withOpacity(0.3),
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              children: [
                                IconButton(
                                  icon: Icon(
                                    _isAudioPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    color: Colors.cyan,
                                    size: 16,
                                  ),
                                  onPressed: () async {
                                    if (_isAudioPlaying) {
                                      await _audioPlayer.pause();
                                    } else {
                                      await _playAudioData(entry.audioData!);
                                    }
                                  },
                                  constraints: BoxConstraints(
                                    minWidth: 24,
                                    minHeight: 24,
                                  ),
                                  padding: EdgeInsets.all(2),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.stop,
                                    color: Colors.cyan,
                                    size: 16,
                                  ),
                                  onPressed: () async {
                                    await _audioPlayer.stop();
                                    setState(() {
                                      _isAudioPlaying = false;
                                    });
                                  },
                                  constraints: BoxConstraints(
                                    minWidth: 24,
                                    minHeight: 24,
                                  ),
                                  padding: EdgeInsets.all(2),
                                ),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '🎵 Audio: ${entry.audioData!.properties.duration.toStringAsFixed(1)}s',
                                        style: TextStyle(
                                          color: Colors.cyan,
                                          fontSize: 7,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        '${entry.audioData!.properties.sampleRate}Hz, '
                                        '${entry.audioData!.properties.channels} ch, '
                                        '${entry.audioData!.properties.bitDepth}-bit',
                                        style: TextStyle(
                                          color: Colors.cyan.withOpacity(0.8),
                                          fontSize: 6,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),

          // Enhanced Input Area
          Container(
            padding: const EdgeInsets.all(6),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    style: const TextStyle(fontSize: 10),
                    decoration: const InputDecoration(
                      hintText: 'Type message...',
                      hintStyle: TextStyle(fontSize: 10),
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 6),
                ElevatedButton.icon(
                  onPressed: (_targetCharacteristic != null && _isConnected)
                      ? _sendMessage
                      : null,
                  icon: const Icon(Icons.send, size: 12),
                  label: const Text('Send', style: TextStyle(fontSize: 10)),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    minimumSize: const Size(60, 30),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
