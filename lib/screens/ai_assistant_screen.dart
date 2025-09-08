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

class _AIAssistantScreenState extends State<AIAssistantScreen>
    with TickerProviderStateMixin {
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
  final TextEditingController _commandController = TextEditingController();

  // Text-to-Speech controller
  FlutterTts flutterTts = FlutterTts();

  // Animation controllers
  late AnimationController _pulseController;
  late AnimationController _rotationController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _rotationAnimation;

  // Available capture commands to try
  final List<String> _captureCommands = [
    'CAPTURE',
    'capture',
    'IMG_CAPTURE',
    'PHOTO',
    'photo',
    'TAKE_PHOTO',
    'snap',
    'camera',
    'pic',
  ];
  int _currentCommandIndex = 0;

  // Gemini API configuration
  static const String _geminiApiKey = 'AIzaSyBDNBVgfzS_nxgrkn879-WZDwQebmNCgXc';
  static const String _geminiApiUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent';

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _setupConnection();
    _initializeTts();
  }

  void _initializeAnimations() {
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _rotationController = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    );

    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _rotationAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _rotationController, curve: Curves.linear),
    );
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

    _pulseController.repeat(reverse: true);
    _rotationController.repeat();

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
      _pulseController.stop();
      _rotationController.stop();
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

  Future<void> _sendCustomCommand() async {
    if (_targetCharacteristic == null || !_isConnected) {
      setState(() {
        _errorMessage = 'Device not connected or characteristic not found';
      });
      return;
    }

    final commandText = _commandController.text.trim();
    if (commandText.isEmpty) return;

    try {
      final command = utf8.encode(commandText);
      await _targetCharacteristic!.write(command);
      _commandController.clear();

      setState(() {
        _errorMessage = 'Sent: $commandText';
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to send command: $e';
      });
    }
  }

  double get _imageProgress {
    if (_expectedImageSize == 0) return 0.0;
    return _imageBuffer.length / _expectedImageSize;
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rotationController.dispose();
    _connectionStateSubscription.cancel();
    _notificationSubscription?.cancel();
    _commandController.dispose();
    flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Assistant'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: Icon(
              _isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: _isConnected ? Colors.green : Colors.red,
            ),
            onPressed: null,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Status Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Icon(
                      _isConnected ? Icons.check_circle : Icons.error,
                      color: _isConnected ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isConnected
                          ? 'Connected to ${widget.device.platformName}'
                          : 'Disconnected',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Main Content Area
            Expanded(child: _buildMainContent()),

            // Capture Button
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 60,
              child: ElevatedButton.icon(
                onPressed:
                    (_isConnected && !_receivingImage && !_processingImage)
                    ? _captureImage
                    : null,
                icon: const Icon(Icons.camera_alt, size: 24),
                label: const Text(
                  'Capture & Analyze Image',
                  style: TextStyle(fontSize: 18),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    if (_errorMessage != null) {
      return _buildErrorCard();
    }

    if (_receivingImage) {
      return _buildReceivingImageCard();
    }

    if (_processingImage) {
      return _buildProcessingCard();
    }

    if (_capturedImage != null && _imageCaption != null) {
      return _buildResultCard();
    }

    return _buildWelcomeCard();
  }

  Widget _buildWelcomeCard() {
    return Card(
      elevation: 4,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.smart_toy, size: 80, color: Colors.blue[300]),
            const SizedBox(height: 16),
            Text(
              'AI Assistant',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Capture an image and let AI describe what it sees',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            const Icon(Icons.arrow_downward, size: 32, color: Colors.grey),
            const SizedBox(height: 8),
            Text(
              'Tap the button below to start',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            Text(
              'Next command to try: ${_captureCommands[_currentCommandIndex]}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[500],
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            Text(
              'Or send a custom command:',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _commandController,
                    decoration: const InputDecoration(
                      hintText: 'Enter command...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _sendCustomCommand(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isConnected ? _sendCustomCommand : null,
                  child: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceivingImageCard() {
    final percentage = (_imageProgress * 100).toStringAsFixed(1);

    return Card(
      elevation: 4,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(strokeWidth: 6),
            const SizedBox(height: 24),
            Text(
              'Receiving Image...',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _imageProgress,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
            ),
            const SizedBox(height: 8),
            Text(
              '$percentage% (${_imageBuffer.length}/$_expectedImageSize bytes)',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingCard() {
    return Card(
      elevation: 4,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _pulseAnimation.value,
                  child: AnimatedBuilder(
                    animation: _rotationAnimation,
                    builder: (context, child) {
                      return Transform.rotate(
                        angle: _rotationAnimation.value * 2 * 3.14159,
                        child: const Icon(
                          Icons.psychology,
                          size: 80,
                          color: Colors.purple,
                        ),
                      );
                    },
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            Text(
              'AI is analyzing...',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Processing image with Gemini AI',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard() {
    return Card(
      elevation: 4,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.image, color: Colors.green),
                const SizedBox(width: 8),
                Text(
                  'Image Analysis Complete',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(color: Colors.green),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Image Preview
            if (_capturedImage != null)
              Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    _capturedImage!,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        color: Colors.grey[200],
                        child: const Center(
                          child: Text('Image preview not available'),
                        ),
                      );
                    },
                  ),
                ),
              ),

            const SizedBox(height: 16),

            // AI Caption
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.smart_toy, color: Colors.blue[700]),
                      const SizedBox(width: 8),
                      Text(
                        'AI Description:',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.blue[700],
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const Spacer(),
                      // TTS Controls
                      IconButton(
                        onPressed: _isSpeaking
                            ? _stopSpeaking
                            : () => _speakText(_imageCaption ?? ''),
                        icon: Icon(
                          _isSpeaking ? Icons.stop : Icons.volume_up,
                          color: Colors.blue[700],
                        ),
                        tooltip: _isSpeaking ? 'Stop speaking' : 'Read aloud',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _imageCaption ?? '',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard() {
    return Card(
      elevation: 4,
      color: Colors.red[50],
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, size: 80, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              'Error',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(color: Colors.red),
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? '',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _errorMessage = null;
                });
              },
              child: const Text('Dismiss'),
            ),
          ],
        ),
      ),
    );
  }
}
