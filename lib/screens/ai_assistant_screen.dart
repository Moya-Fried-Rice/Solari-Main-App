import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';

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

/// VQA data wrapper class that contains both image and audio
class VQAData {
  final Uint8List? imageData;
  final AudioData? audioData;
  final String? transcribedText;
  final DateTime timestamp;
  final Map<String, dynamic>? imageProperties;
  final Map<String, dynamic>? audioProperties;

  VQAData({
    this.imageData,
    this.audioData,
    this.transcribedText,
    required this.timestamp,
    this.imageProperties,
    this.audioProperties,
  });

  bool get isComplete => imageData != null && audioData != null;
  bool get hasImage => imageData != null;
  bool get hasAudio => audioData != null;
  bool get hasTranscription =>
      transcribedText != null && transcribedText!.isNotEmpty;
}

/// AI Assistant Screen for VQA (Visual Question Answering) via BLE and processing with Gemini AI
///
/// This screen provides an AI-powered VQA feature that:
/// 1. Connects to a BLE device
/// 2. Sends VQA capture commands to the device
/// 3. Receives both audio and image data from the device in sequence
/// 4. Processes the VQA data with Google's Gemini AI API
/// 5. Displays the AI-generated response and provides audio playback
///
/// Features:
/// - VQA protocol: Audio streaming first, then image capture
/// - Animated loading indicators during processing
/// - Real-time audio and image transfer progress
/// - Audio playback of recorded VQA audio
/// - Error handling and user feedback
class AIAssistantScreen extends StatefulWidget {
  final BluetoothDevice device;

  const AIAssistantScreen({super.key, required this.device});

  @override
  State<AIAssistantScreen> createState() => _AIAssistantScreenState();
}

class _AIAssistantScreenState extends State<AIAssistantScreen> {
  // Connection management
  late StreamSubscription<BluetoothConnectionState>
  _connectionStateSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  BluetoothCharacteristic? _targetCharacteristic;
  bool _isConnected = false;

  // VQA reception state
  bool _receivingVQA = false;
  bool _vqaImageReceived = false;
  bool _vqaAudioReceived = false;
  bool _receivingVQAAudio = false;
  bool _processingVQA = false;
  bool _isSpeaking = false;

  // VQA data buffers and tracking
  int _vqaExpectedImageSize = 0;
  final List<int> _vqaImageBuffer = [];
  final List<int> _vqaAudioBuffer = [];

  // UI update throttling to prevent overload
  DateTime _lastUIUpdate = DateTime.now();
  static const Duration _uiUpdateThrottle = Duration(
    milliseconds: 100,
  ); // Update UI at most every 100ms

  // VQA results
  Uint8List? _vqaImageData;
  AudioData? _vqaAudioData;
  VQAData? _completedVQAData;
  String? _vqaResponse;
  String? _errorMessage;
  String? _statusMessage;

  // Audio player for VQA audio playback
  final AudioPlayer _audioPlayer = AudioPlayer();

  // Text-to-Speech controller
  FlutterTts flutterTts = FlutterTts();

  // Available VQA commands
  final List<String> _vqaCommands = ['VQA_START'];
  int _currentCommandIndex = 0;

  // Gemini API configuration
  static const String _geminiApiKey = 'AIzaSyBDNBVgfzS_nxgrkn879-WZDwQebmNCgXc';
  static const String _geminiApiUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';

  @override
  void initState() {
    super.initState();
    _setupConnection();
    _initializeTts();
  }

  /// Throttled setState to prevent UI overload during data streaming
  void _throttledSetState([VoidCallback? fn]) {
    final now = DateTime.now();
    if (now.difference(_lastUIUpdate) >= _uiUpdateThrottle) {
      _lastUIUpdate = now;
      setState(fn ?? () {});
    }
  }

  void _initializeTts() {
    flutterTts.setLanguage("en-US");
    flutterTts.setSpeechRate(0.5);
    flutterTts.setVolume(1.0);
    flutterTts.setPitch(1.0);

    flutterTts.setStartHandler(() {
      setState(() {
        _isSpeaking = true;
      });
    });

    flutterTts.setCompletionHandler(() {
      setState(() {
        _isSpeaking = false;
      });
    });

    flutterTts.setErrorHandler((message) {
      setState(() {
        _isSpeaking = false;
      });
    });
  }

  /// Transcribe audio data to text using Gemini Speech-to-Text API
  Future<String?> _transcribeAudio(Uint8List audioData) async {
    try {
      // Convert PCM to WAV format for better compatibility
      final wavData = _convertPcmToWav(audioData, 8000, 1, 16);
      final base64Audio = base64Encode(wavData);

      print(
        'Starting Gemini STT transcription for ${audioData.length} bytes of audio',
      );

      final requestBody = {
        'contents': [
          {
            'parts': [
              {
                'text':
                    'Please transcribe the following audio to text. Return only the transcribed text without any additional commentary.',
              },
              {
                'inline_data': {'mime_type': 'audio/wav', 'data': base64Audio},
              },
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.1,
          'topK': 1,
          'topP': 1,
          'maxOutputTokens': 200,
        },
      };

      final response = await http.post(
        Uri.parse('$_geminiApiUrl?key=$_geminiApiKey'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(requestBody),
      );

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final candidates = responseData['candidates'] as List?;

        if (candidates != null && candidates.isNotEmpty) {
          final content = candidates[0]['content'];
          final parts = content['parts'] as List?;

          if (parts != null && parts.isNotEmpty) {
            final transcription = parts[0]['text'] as String?;
            print('Gemini STT Result: $transcription');
            return transcription?.trim();
          }
        }
      } else {
        print(
          'Gemini STT API Error: ${response.statusCode} - ${response.body}',
        );
        return 'Audio transcription failed (HTTP ${response.statusCode})';
      }

      return 'No transcription returned from Gemini';
    } catch (e) {
      print('Failed to transcribe audio with Gemini: $e');
      return 'Transcription error: $e';
    }
  }

  /// Show dialog to manually enter question text
  Future<String?> _showManualTranscriptionDialog() async {
    String? inputText;

    return showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Edit Question'),
          content: TextField(
            onChanged: (value) {
              inputText = value;
            },
            decoration: const InputDecoration(
              hintText: 'Type what you asked about the image...',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(inputText),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  void _setupConnection() {
    _connectionStateSubscription = widget.device.connectionState.listen((
      state,
    ) {
      if (mounted) {
        setState(() {
          _isConnected = state == BluetoothConnectionState.connected;
        });
        if (_isConnected) {
          _discoverServices();
        }
      }
    });

    // Connect if not already connected
    if (widget.device.isDisconnected) {
      widget.device.connect();
    }
  }

  Future<void> _discoverServices() async {
    try {
      final services = await widget.device.discoverServices();
      for (final service in services) {
        for (final characteristic in service.characteristics) {
          if (characteristic.properties.write ||
              characteristic.properties.writeWithoutResponse) {
            if (characteristic.properties.notify) {
              setState(() {
                _targetCharacteristic = characteristic;
              });
              await _subscribeToNotifications();
              break;
            }
          }
        }
        if (_targetCharacteristic != null) break;
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to discover services: $e';
      });
    }
  }

  Future<void> _subscribeToNotifications() async {
    if (_targetCharacteristic == null) return;

    try {
      await _targetCharacteristic!.setNotifyValue(true);
      _notificationSubscription = _targetCharacteristic!.onValueReceived.listen(
        _processIncomingData,
      );
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to subscribe: $e';
      });
    }
  }

  void _processIncomingData(List<int> value) {
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

    // Handle VQA text commands
    if (isTextCommand) {
      // VQA session start
      if (dataStr == 'VQA_START') {
        _receivingVQA = true;
        _vqaImageReceived = false;
        _vqaAudioReceived = false;
        _vqaImageBuffer.clear();
        _vqaAudioBuffer.clear();
        print('VQA: Starting VQA data reception');
        _receivingVQAAudio = false;
        _errorMessage = null;
        _vqaResponse = null;
        _completedVQAData = null;

        setState(() {});
        return;
      }

      // Audio streaming start (optional, but good for clarity)
      if (dataStr == 'A_START') {
        if (_receivingVQA && !_receivingVQAAudio) {
          _receivingVQAAudio = true;
          _vqaAudioBuffer.clear();
          setState(() {});
        }
        return;
      }

      // Audio streaming end
      if (dataStr == 'A_END') {
        if (_receivingVQA && !_vqaAudioReceived) {
          _finishVQAAudioReception();
          _receivingVQAAudio = false;
        }
        return;
      }

      // Image header with size
      if (dataStr.startsWith('I:')) {
        final sizeStr = dataStr.substring(2); // "I:".length = 2
        try {
          _vqaExpectedImageSize = int.parse(sizeStr);
          _vqaImageBuffer.clear();
          setState(() {});
        } catch (e) {
          setState(() {
            _errorMessage = 'Invalid VQA image size: $sizeStr';
          });
        }
        return;
      }

      // Image end
      if (dataStr == 'I_END') {
        if (_receivingVQA && _vqaAudioReceived && !_vqaImageReceived) {
          _finishVQAImageReception();
        }
        return;
      }

      // VQA session complete
      if (dataStr == 'VQA_END') {
        if (_receivingVQA) {
          _finishVQAReception();
        }
        return;
      }

      // VQA session error
      if (dataStr == 'VQA_ERR') {
        if (_receivingVQA) {
          setState(() {
            _errorMessage = 'VQA session failed';
            _resetVQAState();
          });
        }
        return;
      }
    }

    // Add data to appropriate VQA buffer if receiving
    if (_receivingVQA) {
      if (_receivingVQAAudio && !_vqaAudioReceived) {
        // Currently receiving VQA audio stream
        _vqaAudioBuffer.addAll(value);
        _throttledSetState(); // Throttled UI update for progress
      } else if (_vqaAudioReceived &&
          !_vqaImageReceived &&
          _vqaExpectedImageSize > 0) {
        // Currently receiving VQA image
        _vqaImageBuffer.addAll(value);
        _throttledSetState(); // Throttled UI update for progress
      }
    }
  }

  /// Reset VQA state on error or cancellation
  void _resetVQAState() {
    setState(() {
      _receivingVQA = false;
      _vqaImageReceived = false;
      _vqaAudioReceived = false;
      _receivingVQAAudio = false;
      _vqaImageData = null;
      _vqaAudioData = null;
      _completedVQAData = null;
      _vqaExpectedImageSize = 0;
      _vqaImageBuffer.clear();
      _vqaAudioBuffer.clear();
    });
  }

  /// Finish VQA audio reception
  void _finishVQAAudioReception() {
    try {
      final actualSize = _vqaAudioBuffer.length;

      final audioData = Uint8List.fromList(_vqaAudioBuffer);

      // Default properties for VQA streaming (8kHz, 16-bit, mono PCM)
      final audioProperties = AudioProperties(
        sampleRate: 8000,
        channels: 1,
        bitDepth: 16,
        duration: actualSize / (8000 * 2 * 1), // Duration calculation for PCM
        format: 'PCM',
      );

      _vqaAudioData = AudioData(data: audioData, properties: audioProperties);
      _vqaAudioReceived = true;

      setState(() {});
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to process VQA audio: $e';
      });
    }
  }

  /// Finish VQA image reception
  void _finishVQAImageReception() {
    try {
      final imageData = Uint8List.fromList(_vqaImageBuffer);
      _vqaImageData = imageData;
      _vqaImageReceived = true;

      setState(() {});
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to process VQA image: $e';
      });
    }
  }

  /// Finish complete VQA reception and process with AI
  void _finishVQAReception() async {
    try {
      // Transcribe audio using Gemini STT
      String? transcription;
      if (_vqaAudioData != null) {
        setState(() {
          _statusMessage = 'Transcribing audio with Gemini...';
          _errorMessage = null;
        });

        transcription = await _transcribeAudio(_vqaAudioData!.data);

        setState(() {
          _statusMessage = null; // Clear the transcribing message
        });
      }

      // Create VQA data object with transcription
      final vqaData = VQAData(
        imageData: _vqaImageData,
        audioData: _vqaAudioData,
        transcribedText: transcription,
        timestamp: DateTime.now(),
      );

      _completedVQAData = vqaData;

      // Reset VQA reception state but keep the data
      setState(() {
        _receivingVQA = false;
        _vqaImageReceived = false;
        _vqaAudioReceived = false;
        _receivingVQAAudio = false;
        _vqaExpectedImageSize = 0;
        _vqaImageBuffer.clear();
        _vqaAudioBuffer.clear();
      });

      // Process VQA with AI
      if (vqaData.isComplete) {
        _processVQAWithAI();
      } else {
        setState(() {
          _errorMessage = 'Incomplete VQA data received';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to finalize VQA operation: $e';
        _resetVQAState();
      });
    }
  }

  /// Process VQA data with Gemini AI
  Future<void> _processVQAWithAI() async {
    if (_completedVQAData == null || !_completedVQAData!.isComplete) return;

    setState(() {
      _processingVQA = true;
      _errorMessage = null;
    });

    try {
      final base64Image = base64Encode(_completedVQAData!.imageData!);
      final transcription =
          _completedVQAData!.transcribedText ??
          'No audio transcription available';

      final requestBody = {
        'contents': [
          {
            'parts': [
              {
                'text':
                    'Question: "$transcription". Response in only 1 to 2 short sentences.',
              },
              {
                'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image},
              },
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.7,
          'topK': 32,
          'topP': 1,
          'maxOutputTokens': 1000,
        },
      };

      final response = await http.post(
        Uri.parse('$_geminiApiUrl?key=$_geminiApiKey'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(requestBody),
      );

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final candidates = responseData['candidates'] as List?;

        if (candidates != null && candidates.isNotEmpty) {
          final content = candidates[0]['content'];
          final parts = content['parts'] as List?;

          if (parts != null && parts.isNotEmpty) {
            final vqaResponse = parts[0]['text'] as String?;
            setState(() {
              _vqaResponse = vqaResponse ?? 'No response generated';
            });

            // Automatically speak the response
            if (_vqaResponse != null && _vqaResponse!.isNotEmpty) {
              _speakText(_vqaResponse!);
            }
          } else {
            setState(() {
              _errorMessage = 'No response in AI result';
            });
          }
        } else {
          setState(() {
            _errorMessage = 'No candidates in AI response';
          });
        }
      } else {
        setState(() {
          _errorMessage =
              'AI API Error: ${response.statusCode}\n${response.body}';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to process VQA with AI: $e';
      });
    } finally {
      setState(() {
        _processingVQA = false;
      });
    }
  }

  Future<void> _speakText(String text) async {
    try {
      await flutterTts.speak(text);
    } catch (e) {
      print('Error speaking text: $e');
    }
  }

  Future<void> _stopSpeaking() async {
    try {
      await flutterTts.stop();
      setState(() {
        _isSpeaking = false;
      });
    } catch (e) {
      print('Error stopping speech: $e');
    }
  }

  Future<void> _startVQACapture() async {
    if (_targetCharacteristic == null || !_isConnected) {
      setState(() {
        _errorMessage = 'Device not connected or characteristic not found';
      });
      return;
    }

    try {
      setState(() {
        _errorMessage = null;
        _vqaResponse = null;
        _completedVQAData = null;
        _resetVQAState();
      });

      // Send VQA_START command
      final command = utf8.encode(_vqaCommands[_currentCommandIndex]);
      await _targetCharacteristic!.write(command);

      // Cycle to next command for next attempt
      _currentCommandIndex = (_currentCommandIndex + 1) % _vqaCommands.length;
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to send VQA command: $e';
      });
    }
  }

  /// Stop VQA audio recording and proceed to image capture
  Future<void> _stopVQACapture() async {
    if (_targetCharacteristic == null || !_isConnected) {
      return;
    }

    // Only allow stopping if we're currently receiving audio
    if (!_receivingVQAAudio || _vqaAudioReceived) {
      return;
    }

    try {
      // Send VQA_STOP command to Arduino to stop audio recording and proceed to image
      final stopCommand = utf8.encode('VQA_STOP');
      await _targetCharacteristic!.write(stopCommand);

      print(
        'VQA: Sent VQA_STOP command - Arduino should stop recording and capture image',
      );

      // Don't reset state - let the Arduino proceed with image capture
      // The audio reception will be marked complete when Arduino sends A_END
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to send VQA_STOP command: $e';
      });
    }
  }

  /// Get VQA progress information
  String get _vqaProgressText {
    if (_receivingVQAAudio && !_vqaAudioReceived) {
      return 'Receiving Audio: ${(_vqaAudioBuffer.length / 1024.0).toStringAsFixed(1)} KB';
    } else if (_vqaAudioReceived &&
        !_vqaImageReceived &&
        _vqaExpectedImageSize > 0) {
      final percentage =
          ((_vqaImageBuffer.length / _vqaExpectedImageSize) * 100)
              .toStringAsFixed(1);
      return 'Receiving Image: $percentage% (${_vqaImageBuffer.length}/${_vqaExpectedImageSize} bytes)';
    } else if (_vqaAudioReceived && !_vqaImageReceived) {
      return 'Audio complete, waiting for image...';
    } else if (_processingVQA) {
      return 'Processing with AI...';
    }
    return 'Initializing VQA...';
  }

  /// Play VQA audio data
  Future<void> _playVQAAudio() async {
    if (_completedVQAData?.audioData == null) return;

    try {
      // Convert PCM to WAV format for playback
      final audioData = _completedVQAData!.audioData!;
      final wavData = _convertPcmToWav(
        audioData.data,
        audioData.properties.sampleRate,
        audioData.properties.channels,
        audioData.properties.bitDepth,
      );

      await _audioPlayer.play(BytesSource(wavData));
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to play VQA audio: $e';
      });
    }
  }

  /// Convert raw PCM data to WAV format
  Uint8List _convertPcmToWav(
    Uint8List pcmData,
    int sampleRate,
    int channels,
    int bitDepth,
  ) {
    final int dataSize = pcmData.length;
    final int fileSize = 36 + dataSize;
    final int byteRate = sampleRate * channels * (bitDepth ~/ 8);
    final int blockAlign = channels * (bitDepth ~/ 8);

    final ByteData wavHeader = ByteData(44);

    // RIFF header
    wavHeader.setUint8(0, 0x52); // 'R'
    wavHeader.setUint8(1, 0x49); // 'I'
    wavHeader.setUint8(2, 0x46); // 'F'
    wavHeader.setUint8(3, 0x46); // 'F'
    wavHeader.setUint32(4, fileSize, Endian.little); // File size
    wavHeader.setUint8(8, 0x57); // 'W'
    wavHeader.setUint8(9, 0x41); // 'A'
    wavHeader.setUint8(10, 0x56); // 'V'
    wavHeader.setUint8(11, 0x45); // 'E'

    // fmt chunk
    wavHeader.setUint8(12, 0x66); // 'f'
    wavHeader.setUint8(13, 0x6D); // 'm'
    wavHeader.setUint8(14, 0x74); // 't'
    wavHeader.setUint8(15, 0x20); // ' '
    wavHeader.setUint32(16, 16, Endian.little); // fmt chunk size
    wavHeader.setUint16(20, 1, Endian.little); // Audio format (PCM)
    wavHeader.setUint16(22, channels, Endian.little); // Number of channels
    wavHeader.setUint32(24, sampleRate, Endian.little); // Sample rate
    wavHeader.setUint32(28, byteRate, Endian.little); // Byte rate
    wavHeader.setUint16(32, blockAlign, Endian.little); // Block align
    wavHeader.setUint16(34, bitDepth, Endian.little); // Bits per sample

    // data chunk
    wavHeader.setUint8(36, 0x64); // 'd'
    wavHeader.setUint8(37, 0x61); // 'a'
    wavHeader.setUint8(38, 0x74); // 't'
    wavHeader.setUint8(39, 0x61); // 'a'
    wavHeader.setUint32(40, dataSize, Endian.little); // Data size

    // Combine header and PCM data
    final result = Uint8List(44 + dataSize);
    result.setRange(0, 44, wavHeader.buffer.asUint8List());
    result.setRange(44, 44 + dataSize, pcmData);

    return result;
  }

  /// Get dynamic button text based on VQA state
  String _getVQAButtonText() {
    if (!_isConnected) {
      return '[DISCONNECTED]';
    } else if (_processingVQA) {
      return '[PROCESSING...]';
    } else if (_receivingVQA) {
      if (_receivingVQAAudio && !_vqaAudioReceived) {
        return '[STOP RECORDING]';
      } else if (_vqaAudioReceived && !_vqaImageReceived) {
        if (_vqaExpectedImageSize > 0) {
          final percentage =
              ((_vqaImageBuffer.length / _vqaExpectedImageSize) * 100)
                  .toStringAsFixed(0);
          return '[RECEIVING IMAGE $percentage%]';
        } else {
          return '[WAITING FOR IMAGE...]';
        }
      } else {
        return '[RECEIVING VQA...]';
      }
    } else {
      return '[START VQA]';
    }
  }

  /// Get dynamic button action based on VQA state
  VoidCallback? _getVQAButtonAction() {
    if (!_isConnected) {
      return null;
    } else if (_processingVQA) {
      return null; // Disabled during processing
    } else if (_receivingVQAAudio && !_vqaAudioReceived) {
      return _stopVQACapture; // Stop recording audio
    } else if (_receivingVQA) {
      return null; // Disabled during other VQA operations
    } else {
      return _startVQACapture; // Start VQA
    }
  }

  /// Get dynamic button color based on VQA state
  Color? _getVQAButtonColor() {
    if (!_isConnected) {
      return Colors.grey[300];
    } else if (_processingVQA) {
      return Colors.orange[100];
    } else if (_receivingVQAAudio && !_vqaAudioReceived) {
      return Colors.red[100]; // Red when recording (stop action)
    } else if (_receivingVQA) {
      return Colors.blue[100];
    } else {
      return Colors.white;
    }
  }

  @override
  void dispose() {
    _connectionStateSubscription.cancel();
    _notificationSubscription?.cancel();
    flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Assistant - DEV', style: TextStyle(fontSize: 14)),
        backgroundColor: _isConnected ? Colors.green[100] : Colors.red[100],
        foregroundColor: Colors.black,
      ),
      body: Container(
        color: Colors.grey[50],
        child: Column(
          children: [
            // Simple Status Bar
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                color: Colors.white,
              ),
              child: Text(
                'Status: ${_isConnected ? 'Connected' : 'Disconnected'} | Device: ${widget.device.platformName}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
              ),
            ),

            // Main Content Area (Scrollable)
            Expanded(child: _buildSimpleContent()),

            // Smart VQA Button
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(6),
              height: 40,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                color: _getVQAButtonColor(),
              ),
              child: InkWell(
                onTap: _getVQAButtonAction(),
                child: Center(
                  child: Text(
                    _getVQAButtonText(),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: _isConnected ? Colors.black : Colors.grey[600],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSimpleContent() {
    // Show status message (like transcription progress)
    if (_statusMessage != null) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.blue),
          color: Colors.blue[50],
        ),
        child: Column(
          children: [
            const Text(
              '[STATUS]',
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _statusMessage ?? '',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return SingleChildScrollView(
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.all(6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.red),
            color: Colors.red[50],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '[ERROR]',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage ?? '',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  color: Colors.white,
                ),
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _errorMessage = null;
                    });
                  },
                  child: const Text(
                    '[DISMISS]',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_receivingVQAAudio || _vqaImageReceived || _vqaAudioReceived) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.blue),
          color: Colors.blue[50],
        ),
        child: Column(
          children: [
            const Text(
              '[VQA CAPTURE IN PROGRESS]',
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _vqaProgressText,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
            ),
          ],
        ),
      );
    }

    if (_processingVQA) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.purple),
          color: Colors.purple[50],
        ),
        child: const Column(
          children: [
            Text(
              '[PROCESSING...]',
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'AI analyzing image...',
              style: TextStyle(fontFamily: 'monospace', fontSize: 10),
            ),
          ],
        ),
      );
    }

    if (_completedVQAData != null && _vqaResponse != null) {
      return SingleChildScrollView(
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.all(6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.green),
            color: Colors.green[50],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '[VQA RESULT]',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),

              // Show transcribed question with edit option
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.blue),
                  color: Colors.blue[50],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '[QUESTION TRANSCRIPTION]',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                            fontSize: 10,
                          ),
                        ),
                        InkWell(
                          onTap: () async {
                            final newText =
                                await _showManualTranscriptionDialog();
                            if (newText != null && newText.isNotEmpty) {
                              setState(() {
                                _completedVQAData = VQAData(
                                  imageData: _completedVQAData!.imageData,
                                  audioData: _completedVQAData!.audioData,
                                  transcribedText: newText,
                                  timestamp: _completedVQAData!.timestamp,
                                );
                              });
                              // Reprocess with new transcription
                              _processVQAWithAI();
                            }
                          },
                          child: const Text(
                            '[EDIT]',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 8,
                              color: Colors.blue,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _completedVQAData?.transcribedText ??
                          'No transcription available',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Display VQA image
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  color: Colors.white,
                ),
                child: _completedVQAData?.imageData != null
                    ? Image.memory(
                        _completedVQAData!.imageData!,
                        fit: BoxFit.fitHeight,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            height: 100,
                            color: Colors.grey[200],
                            child: const Center(
                              child: Text(
                                '[IMAGE ERROR]',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          );
                        },
                      )
                    : Container(
                        height: 100,
                        color: Colors.grey[100],
                        child: const Center(
                          child: Text(
                            '[NO IMAGE]',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
              ),

              const SizedBox(height: 12),

              // AI caption
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  color: Colors.white,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '[AI DESCRIPTION]',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _vqaResponse ?? '',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Audio controls - both VQA audio and TTS
              Row(
                children: [
                  // Play VQA audio button
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        color: Colors.white,
                      ),
                      child: InkWell(
                        onTap: _completedVQAData?.audioData != null
                            ? _playVQAAudio
                            : null,
                        child: const Text(
                          '[PLAY VQA AUDIO]',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // TTS button
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        color: Colors.white,
                      ),
                      child: InkWell(
                        onTap: _isSpeaking
                            ? _stopSpeaking
                            : () => _speakText(_vqaResponse ?? ''),
                        child: Text(
                          _isSpeaking ? '[STOP TTS]' : '[SPEAK TEXT]',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // Default welcome state
    return SizedBox(
      height: MediaQuery.of(context).size.height,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
          color: Colors.grey[50],
        ),
        child: Column(
          children: [
            const Text(
              '[AI ASSISTANT - DEV MODE]',
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Ready to capture and analyze images',
              style: TextStyle(fontFamily: 'monospace', fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}
