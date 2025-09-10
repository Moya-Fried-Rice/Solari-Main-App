import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// AI Assistant Screen for capturing images via BLE and processing them with Gemini AI
///
/// This screen provides two AI-powered features:
/// 1. Image Analysis - Captures images and provides AI descriptions
/// 2. VQA (Visual Question Answering) - Captures image + audio question for AI analysis
///
/// Features:
/// - Tabbed interface for different AI modes
/// - Animated loading indicators during processing
/// - Speech-to-text conversion for VQA
/// - Real-time data transfer progress
/// - Error handling and user feedback
class AIAssistantScreen extends StatefulWidget {
  final BluetoothDevice device;

  const AIAssistantScreen({super.key, required this.device});

  @override
  State<AIAssistantScreen> createState() => _AIAssistantScreenState();
}

class _AIAssistantScreenState extends State<AIAssistantScreen>
    with SingleTickerProviderStateMixin {
  // Tab controller
  late TabController _tabController;

  // Connection management
  late StreamSubscription<BluetoothConnectionState>
  _connectionStateSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  BluetoothCharacteristic? _targetCharacteristic;
  bool _isConnected = false;

  // Image capture state (for Image Analysis tab)
  bool _receivingImage = false;
  bool _processingImage = false;
  bool _isSpeaking = false;
  int _expectedImageSize = 0;
  final List<int> _imageBuffer = [];
  Uint8List? _capturedImage;
  String? _imageCaption;
  String? _errorMessage;

  // VQA state (for VQA tab)
  bool _vqaMode = false;
  bool _receivingVQA = false;
  bool _vqaImageReceived = false;
  bool _vqaAudioReceived = false;
  bool _processingVQA = false;
  int _vqaExpectedImageSize = 0;
  int _vqaExpectedAudioSize = 0;
  final List<int> _vqaImageBuffer = [];
  final List<int> _vqaAudioBuffer = [];
  Uint8List? _vqaImageData;
  Uint8List? _vqaAudioData;
  String? _vqaTranscription;
  String? _vqaResponse;
  String? _vqaResult;
  String? _vqaErrorMessage;
  String _vqaSpeechText = ''; // Store speech-to-text result

  // Speech-to-text
  late stt.SpeechToText _speechToText;
  bool _speechEnabled = false;

  // Text-to-Speech controller
  FlutterTts flutterTts = FlutterTts();

  // Available capture commands to try
  final List<String> _captureCommands = ['IMAGE'];
  int _currentCommandIndex = 0;

  // Gemini API configuration
  static const String _geminiApiKey = 'AIzaSyBDNBVgfzS_nxgrkn879-WZDwQebmNCgXc';
  static const String _geminiApiUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _setupConnection();
    _initializeTts();
    _initializeSpeechToText();
  }

  void _initializeSpeechToText() async {
    _speechToText = stt.SpeechToText();
    bool available = await _speechToText.initialize(
      onStatus: (val) => print('Speech status: $val'),
      onError: (val) => print('Speech error: $val'),
    );
    if (mounted) {
      setState(() {
        _speechEnabled = available;
      });
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
    // Check if data is a text command
    bool isTextCommand = false;
    String dataStr = '';

    if (value.every((byte) => byte < 128)) {
      try {
        dataStr = utf8.decode(value);
        isTextCommand = true;
      } catch (e) {
        isTextCommand = false;
      }
    }

    if (isTextCommand) {
      // Regular image commands (Image Analysis tab)
      if (dataStr.startsWith('IMG_START:')) {
        final sizeStr = dataStr.substring(10);
        try {
          _expectedImageSize = int.parse(sizeStr);
          _receivingImage = true;
          _imageBuffer.clear();
          _capturedImage = null;
          _imageCaption = null;
          _errorMessage = null;
          setState(() {});
        } catch (e) {
          setState(() {
            _errorMessage = 'Invalid image size: $sizeStr';
          });
        }
        return;
      }

      if (dataStr == 'IMG_END') {
        if (_receivingImage) {
          _finishImageReception();
        }
        return;
      }

      // VQA commands (VQA tab)
      if (dataStr.startsWith('VQA_IMG_START:')) {
        final sizeStr = dataStr.substring(14);
        try {
          _vqaExpectedImageSize = int.parse(sizeStr);
          _receivingVQA = true;
          _vqaImageReceived = false;
          _vqaAudioReceived = false;
          _vqaImageBuffer.clear();
          _vqaImageData = null;
          _vqaAudioData = null;
          _vqaTranscription = null;
          _vqaResponse = null;
          _vqaErrorMessage = null;
          setState(() {});
        } catch (e) {
          setState(() {
            _vqaErrorMessage = 'Invalid VQA image size: $sizeStr';
          });
        }
        return;
      }

      if (dataStr == 'VQA_IMG_END') {
        if (_receivingVQA && !_vqaImageReceived) {
          _finishVQAImageReception();
        }
        return;
      }

      if (dataStr.startsWith('VQA_AUD_START:')) {
        final sizeStr = dataStr.substring(14);
        try {
          _vqaExpectedAudioSize = int.parse(sizeStr);
          _vqaAudioBuffer.clear();
          setState(() {});
        } catch (e) {
          setState(() {
            _vqaErrorMessage = 'Invalid VQA audio size: $sizeStr';
          });
        }
        return;
      }

      if (dataStr == 'VQA_AUD_END') {
        if (_receivingVQA && _vqaImageReceived && !_vqaAudioReceived) {
          _finishVQAAudioReception();
        }
        return;
      }

      if (dataStr == 'VQA_COMPLETE') {
        if (_receivingVQA) {
          _finishVQAReception();
        }
        return;
      }
    }

    // Add data to appropriate buffer
    if (_receivingImage && !_receivingVQA) {
      _imageBuffer.addAll(value);
      setState(() {}); // Update progress
    } else if (_receivingVQA) {
      if (!_vqaImageReceived) {
        _vqaImageBuffer.addAll(value);
        setState(() {}); // Update progress
      } else if (_vqaImageReceived && !_vqaAudioReceived) {
        _vqaAudioBuffer.addAll(value);
        setState(() {}); // Update progress
      }
    }
  }

  void _finishImageReception() {
    if (_imageBuffer.isNotEmpty) {
      setState(() {
        _capturedImage = Uint8List.fromList(_imageBuffer);
        _receivingImage = false;
      });
      _processImageWithGemini();
    } else {
      setState(() {
        _errorMessage = 'No image data received';
        _receivingImage = false;
      });
    }
  }

  Future<void> _processImageWithGemini() async {
    if (_capturedImage == null) return;

    setState(() {
      _processingImage = true;
      _errorMessage = null;
    });

    try {
      final base64Image = base64Encode(_capturedImage!);

      final requestBody = {
        'contents': [
          {
            'parts': [
              {
                'text':
                    'Please provide a detailed caption for this image. Describe what you see, including objects, people, activities, colors, and the overall scene.',
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
          'maxOutputTokens': 4096,
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
            final caption = parts[0]['text'] as String?;
            setState(() {
              _imageCaption = caption ?? 'No caption generated';
            });

            // Automatically speak the caption
            if (_imageCaption != null && _imageCaption!.isNotEmpty) {
              _speakText(_imageCaption!);
            }
          } else {
            setState(() {
              _errorMessage = 'No caption in response';
            });
          }
        } else {
          setState(() {
            _errorMessage = 'No candidates in response';
          });
        }
      } else {
        setState(() {
          _errorMessage = 'API Error: ${response.statusCode}\n${response.body}';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to process image: $e';
      });
    } finally {
      setState(() {
        _processingImage = false;
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

  // VQA Processing Methods
  void _finishVQAImageReception() {
    if (_vqaImageBuffer.isNotEmpty) {
      setState(() {
        _vqaImageData = Uint8List.fromList(_vqaImageBuffer);
        _vqaImageReceived = true;
      });
    } else {
      setState(() {
        _vqaErrorMessage = 'No VQA image data received';
      });
    }
  }

  void _finishVQAAudioReception() {
    if (_vqaAudioBuffer.isNotEmpty) {
      setState(() {
        _vqaAudioData = Uint8List.fromList(_vqaAudioBuffer);
        _vqaAudioReceived = true;
      });
      _processAudioToText();
    } else {
      setState(() {
        _vqaErrorMessage = 'No VQA audio data received';
      });
    }
  }

  void _finishVQAReception() {
    setState(() {
      _receivingVQA = false;
    });

    if (_vqaImageReceived && _vqaAudioReceived && _vqaTranscription != null) {
      _processVQAWithGemini();
    } else {
      setState(() {
        _vqaErrorMessage =
            'VQA incomplete: Missing image, audio, or transcription';
      });
    }
  }

  Future<void> _processAudioToText() async {
    if (_vqaAudioData == null) return;

    setState(() {
      _processingVQA = true;
      _vqaErrorMessage = null;
    });

    try {
      print('Audio data received: ${_vqaAudioData!.length} bytes');

      // Convert raw audio data to base64 for Google Speech-to-Text API
      final String base64Audio = base64Encode(_vqaAudioData!);

      // Call Gemini for speech-to-text conversion
      final transcription = await _transcribeAudioWithGemini(base64Audio);

      if (transcription != null && transcription.isNotEmpty) {
        setState(() {
          _vqaTranscription = transcription;
          _vqaSpeechText = transcription;
        });
        print('Transcription successful: $transcription');
      } else {
        // Simple fallback when transcription fails
        setState(() {
          _vqaTranscription = "Please describe what you see in this image";
          _vqaSpeechText =
              "Audio transcription failed - using default question";
        });
        print('Transcription failed, using default question');
      }

      // Important: Continue with VQA processing after transcription
      if (_vqaImageReceived && _vqaAudioReceived && _vqaTranscription != null) {
        _processVQAWithGemini();
      }
    } catch (e) {
      setState(() {
        _vqaErrorMessage = 'Failed to transcribe audio: $e';
        _processingVQA = false;
      });
      print('Error in _processAudioToText: $e');
    }
  }

  Future<String?> _transcribeAudioWithGemini(String base64Audio) async {
    try {
      print('Attempting Gemini audio transcription...');

      final requestBody = {
        'contents': [
          {
            'parts': [
              {
                'text':
                    'Please transcribe this audio to text. Provide only the spoken words without any additional commentary.',
              },
              {
                'inline_data': {
                  'mime_type':
                      'audio/wav', // Try different formats: audio/wav, audio/mp3, audio/webm
                  'data': base64Audio,
                },
              },
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.1, // Low temperature for accurate transcription
          'topK': 1,
          'topP': 1,
          'maxOutputTokens': 1024,
        },
      };

      final response = await http.post(
        Uri.parse('$_geminiApiUrl?key=$_geminiApiKey'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(requestBody),
      );

      print('Gemini Audio API Response Status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final candidates = responseData['candidates'] as List?;

        if (candidates != null && candidates.isNotEmpty) {
          final content = candidates[0]['content'];
          final parts = content['parts'] as List?;

          if (parts != null && parts.isNotEmpty) {
            final transcript = parts[0]['text'] as String?;
            print('Gemini transcription successful: $transcript');
            return transcript?.trim();
          }
        }
      } else {
        print(
          'Gemini Audio API Error: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      print('Error calling Gemini Audio API: $e');
    }

    return null;
  }

  Future<void> _processVQAWithGemini() async {
    if (_vqaImageData == null || _vqaTranscription == null) return;

    setState(() {
      _processingVQA = true;
      _vqaErrorMessage = null;
    });

    try {
      final base64Image = base64Encode(_vqaImageData!);

      final requestBody = {
        'contents': [
          {
            'parts': [
              {
                'text':
                    'You are analyzing an image based on this question: "${_vqaTranscription}". Response only in 1 to 2 sentences.',
              },
              {
                'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image},
              },
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.4,
          'topK': 32,
          'topP': 1,
          'maxOutputTokens': 4096,
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
            final answer = parts[0]['text'] as String?;
            setState(() {
              _vqaResult = answer ?? 'No answer generated';
            });

            // Automatically speak the answer
            if (_vqaResult != null && _vqaResult!.isNotEmpty) {
              _speakText(_vqaResult!);
            }
          } else {
            setState(() {
              _vqaErrorMessage = 'No answer in response';
            });
          }
        } else {
          setState(() {
            _vqaErrorMessage = 'No candidates in response';
          });
        }
      } else {
        setState(() {
          _vqaErrorMessage =
              'API Error: ${response.statusCode}\n${response.body}';
        });
      }
    } catch (e) {
      setState(() {
        _vqaErrorMessage = 'Failed to process VQA: $e';
      });
    } finally {
      setState(() {
        _processingVQA = false;
        _vqaMode = false; // Reset VQA mode to enable button for next session
      });
    }
  }

  Future<void> _captureVQA() async {
    if (_targetCharacteristic == null || !_isConnected) {
      setState(() {
        _vqaErrorMessage = 'Device not connected or characteristic not found';
        _vqaMode = false; // Reset VQA mode on error to enable button
      });
      return;
    }

    try {
      setState(() {
        _vqaErrorMessage = null;
        _vqaImageData = null;
        _vqaAudioData = null;
        _vqaTranscription = null;
        _vqaResponse = null;
        _vqaImageReceived = false;
        _vqaAudioReceived = false;
      });

      // Send VQA command to device
      final command = utf8.encode('VQA');
      await _targetCharacteristic!.write(command);
    } catch (e) {
      setState(() {
        _vqaErrorMessage = 'Failed to send VQA command: $e';
        _vqaMode = false; // Reset VQA mode on error to enable button
      });
    }
  }

  Future<void> _startVQA() async {
    setState(() {
      _vqaMode = true;
      _vqaResult = null;
      _vqaImageReceived = false;
      _vqaAudioReceived = false;
      _vqaSpeechText = ''; // Clear previous speech text
    });

    await _captureVQA();
  }

  Future<void> _captureImage() async {
    if (_targetCharacteristic == null || !_isConnected) {
      setState(() {
        _errorMessage = 'Device not connected or characteristic not found';
      });
      return;
    }

    try {
      setState(() {
        _errorMessage = null;
        _capturedImage = null;
        _imageCaption = null;
      });

      // Send the current capture command
      final command = utf8.encode(_captureCommands[_currentCommandIndex]);
      await _targetCharacteristic!.write(command);

      // Cycle to next command for next attempt
      _currentCommandIndex =
          (_currentCommandIndex + 1) % _captureCommands.length;
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to send capture command: $e';
      });
    }
  }

  double get _imageProgress {
    if (_expectedImageSize == 0) return 0.0;
    return _imageBuffer.length / _expectedImageSize;
  }

  @override
  void dispose() {
    _tabController.dispose();
    _connectionStateSubscription.cancel();
    _notificationSubscription?.cancel();
    flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Assistant', style: TextStyle(fontSize: 14)),
        backgroundColor: _isConnected ? Colors.green[100] : Colors.red[100],
        foregroundColor: Colors.black,
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.black,
          indicatorColor: Colors.blue,
          tabs: const [
            Tab(text: 'Image Analysis'),
            Tab(text: 'VQA'),
          ],
        ),
      ),
      body: Container(
        color: Colors.grey[50],
        child: Column(
          children: [
            // Status Bar
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

            // Tab Content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [_buildImageAnalysisTab(), _buildVQATab()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageAnalysisTab() {
    return Column(
      children: [
        // Main Content Area (Scrollable)
        Expanded(child: _buildSimpleContent()),

        // Capture Image Button
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(6),
          height: 40,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey),
            color: _isConnected && !_receivingImage && !_processingImage
                ? Colors.white
                : Colors.grey[300],
          ),
          child: InkWell(
            onTap: (_isConnected && !_receivingImage && !_processingImage)
                ? _captureImage
                : null,
            child: const Center(
              child: Text(
                '[CAPTURE IMAGE]',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVQATab() {
    return Column(
      children: [
        // VQA Content Area
        Expanded(child: _buildVQAContent()),

        // Start VQA Button (console style)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(6),
          height: 40,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey),
            color: _isConnected && !_vqaMode ? Colors.white : Colors.grey[300],
          ),
          child: InkWell(
            onTap: (_isConnected && !_vqaMode) ? _startVQA : null,
            child: const Center(
              child: Text(
                '[START VQA]',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVQAContent() {
    return SingleChildScrollView(
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
          color: Colors.grey[50],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '[VQA CHAT]',
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: Colors.blue,
              ),
            ),
            const SizedBox(height: 8),

            // Show VQA processing status
            if (_vqaMode) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.orange),
                  color: Colors.orange[50],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '[VQA STATUS]',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                        color: Colors.orange,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Image: ${_vqaImageReceived ? 'Received' : 'Waiting...'}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                    Text(
                      'Audio: ${_vqaAudioReceived ? 'Received' : 'Waiting...'}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                    if (_vqaImageReceived && _vqaAudioReceived)
                      const Text(
                        'Processing with Gemini...',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: Colors.orange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
              ),
            ],

            // Show captured image if available
            if (_vqaImageData != null) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.purple),
                  color: Colors.purple[50],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '[CAPTURED IMAGE]',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                        color: Colors.purple,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Image.memory(
                      _vqaImageData!,
                      width: double.infinity,
                      height: 200,
                      fit: BoxFit.cover,
                    ),
                  ],
                ),
              ),
            ],

            // Show speech-to-text result if available
            if (_vqaSpeechText.isNotEmpty) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.blue),
                  color: Colors.blue[50],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '[YOUR QUESTION]',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                        color: Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _vqaSpeechText,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Show AI response if available
            if (_vqaResult != null) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.green),
                  color: Colors.green[50],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '[AI RESPONSE]',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                        color: Colors.green,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _vqaResult!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Show placeholder when no conversation
            if (_vqaSpeechText.isEmpty && _vqaResult == null && !_vqaMode)
              const Text(
                'Start VQA to ask questions about images using voice...',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: Colors.grey,
                  fontStyle: FontStyle.italic,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSimpleContent() {
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

    if (_receivingImage) {
      final percentage = (_imageProgress * 100).toStringAsFixed(1);
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
              '[RECEIVING IMAGE]',
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              height: 6,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                color: Colors.blue[100],
              ),
              child: Stack(
                children: [
                  Container(
                    width:
                        (MediaQuery.of(context).size.width - 64) *
                        _imageProgress,
                    color: Colors.blue[600],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$percentage% (${_imageBuffer.length}/${_expectedImageSize} bytes)',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
            ),
          ],
        ),
      );
    }

    if (_processingImage) {
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

    if (_capturedImage != null && _imageCaption != null) {
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
                '[RESULT]',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),

              // Display actual image
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  color: Colors.white,
                ),
                child: _capturedImage != null
                    ? Image.memory(
                        _capturedImage!,
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
                      _imageCaption ?? '',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // TTS button
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  color: Colors.white,
                ),
                child: InkWell(
                  onTap: _isSpeaking
                      ? _stopSpeaking
                      : () => _speakText(_imageCaption ?? ''),
                  child: Text(
                    _isSpeaking ? '[STOP AUDIO]' : '[PLAY AUDIO]',
                    style: const TextStyle(
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
