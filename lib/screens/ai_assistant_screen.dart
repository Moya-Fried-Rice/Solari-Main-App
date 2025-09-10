import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';

/// AI Assistant Screen for capturing images via BLE and processing them with Gemini AI
///
/// This screen provides an AI-powered image analysis feature that:
/// 1. Connects to a BLE device
/// 2. Sends image capture commands to the device
/// 3. Receives image data from the device
/// 4. Processes the image with Google's Gemini AI API
/// 5. Displays the AI-generated caption/description
///
/// Features:
/// - Animated loading indicators during processing
/// - Multiple capture command attempts for device compatibility
/// - Custom command input for testing
/// - Real-time image transfer progress
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

  // Image capture state
  bool _receivingImage = false;
  bool _processingImage = false;
  bool _isSpeaking = false;
  int _expectedImageSize = 0;
  final List<int> _imageBuffer = [];
  Uint8List? _capturedImage;
  String? _imageCaption;
  String? _errorMessage;

  // Text-to-Speech controller
  FlutterTts flutterTts = FlutterTts();

  // Available capture commands to try
  final List<String> _captureCommands = ['IMAGE'];
  int _currentCommandIndex = 0;

  // Gemini API configuration
  static const String _geminiApiKey = 'AIzaSyBDNBVgfzS_nxgrkn879-WZDwQebmNCgXc';
  static const String _geminiApiUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent';

  @override
  void initState() {
    super.initState();
    _setupConnection();
    _initializeTts();
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
    }

    // Add data to image buffer if receiving
    if (_receivingImage) {
      _imageBuffer.addAll(value);
      setState(() {}); // Update progress
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

            // Simple Button
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
