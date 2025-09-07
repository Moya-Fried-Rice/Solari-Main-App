import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class SolariScreen extends StatefulWidget {
  final BluetoothDevice device;

  const SolariScreen({super.key, required this.device});

  @override
  State<SolariScreen> createState() => _SolariScreenState();
}

class _SolariScreenState extends State<SolariScreen> {
  late StreamSubscription<BluetoothConnectionState>
  _connectionStateSubscription;
  late StreamSubscription<int> _mtuSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  BluetoothCharacteristic? _targetCharacteristic;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<String> _messages = [];
  bool _isConnected = false;
  bool _isSubscribed = false;
  int _currentMtu = 23; // Default BLE MTU

  // Track last sent message to avoid showing it as received
  List<int>? _lastSentData;
  DateTime? _lastSentTime;

  // Target characteristic UUID
  static const String TARGET_CHARACTERISTIC_UUID =
      "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  @override
  void initState() {
    super.initState();
    _connectionStateSubscription = widget.device.connectionState.listen((
      state,
    ) {
      setState(() {
        _isConnected = state == BluetoothConnectionState.connected;
      });
      if (state == BluetoothConnectionState.disconnected) {
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    });

    // Listen to MTU changes
    _mtuSubscription = widget.device.mtu.listen((mtu) {
      setState(() {
        _currentMtu = mtu;
      });
      _addMessage("MTU changed to: $mtu bytes", isSystem: true);
    });

    _findTargetCharacteristic();
    _requestMtu();
  }

  @override
  void dispose() {
    _connectionStateSubscription.cancel();
    _mtuSubscription.cancel();
    _notificationSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _requestMtu() async {
    try {
      // Request larger MTU for better performance
      await widget.device.requestMtu(512);
      _addMessage("Requested MTU: 512 bytes", isSystem: true);
    } catch (e) {
      _addMessage("MTU request failed: $e", isSystem: true);
    }
  }

  Future<void> _findTargetCharacteristic() async {
    try {
      List<BluetoothService> services = await widget.device.discoverServices();

      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.str.toLowerCase() ==
              TARGET_CHARACTERISTIC_UUID.toLowerCase()) {
            setState(() {
              _targetCharacteristic = characteristic;
            });
            _addMessage("Found target characteristic!", isSystem: true);

            // Auto-subscribe to notifications if supported
            if (characteristic.properties.notify) {
              await _subscribeToNotifications();
            }
            return;
          }
        }
      }
      _addMessage("Target characteristic not found!", isSystem: true);
    } catch (e) {
      _addMessage("Error finding characteristic: $e", isSystem: true);
    }
  }

  void _addMessage(
    String message, {
    bool isSystem = false,
    bool isSent = false,
  }) {
    setState(() {
      String prefix = isSystem
          ? "[SYSTEM] "
          : (isSent ? "[SENT] " : "[RECEIVED] ");
      _messages.add("$prefix$message");
    });

    // Auto-scroll to bottom after adding message
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Helper method to compare two lists
  bool _listsEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _subscribeToNotifications() async {
    if (_targetCharacteristic == null) return;

    try {
      // Enable notifications
      await _targetCharacteristic!.setNotifyValue(true);

      // Listen to notifications
      _notificationSubscription = _targetCharacteristic!.lastValueStream.listen(
        (value) {
          // Check if this value matches what we just sent
          bool isEcho = false;
          if (_lastSentData != null && _lastSentTime != null) {
            // Consider it an echo if it matches the last sent data
            // and was received within 1 second of sending
            if (_listsEqual(value, _lastSentData!) &&
                DateTime.now().difference(_lastSentTime!).inMilliseconds <
                    1000) {
              isEcho = true;
            }
          }

          if (!isEcho) {
            String notification;
            try {
              notification = utf8.decode(value);
            } catch (e) {
              notification = value.toString();
            }
            _addMessage("$notification (${value.length} bytes)");
          }
        },
      );

      setState(() {
        _isSubscribed = true;
      });
      _addMessage("Subscribed to notifications!", isSystem: true);
    } catch (e) {
      _addMessage("Failed to subscribe to notifications: $e", isSystem: true);
    }
  }

  Future<void> _unsubscribeFromNotifications() async {
    if (_targetCharacteristic == null) return;

    try {
      await _targetCharacteristic!.setNotifyValue(false);
      _notificationSubscription?.cancel();
      _notificationSubscription = null;

      setState(() {
        _isSubscribed = false;
      });
      _addMessage("Unsubscribed from notifications!", isSystem: true);
    } catch (e) {
      _addMessage(
        "Failed to unsubscribe from notifications: $e",
        isSystem: true,
      );
    }
  }

  Future<void> _sendMessage() async {
    if (_targetCharacteristic == null) {
      _addMessage("Characteristic not ready!", isSystem: true);
      return;
    }

    String message = _messageController.text.trim();
    if (message.isEmpty) return;

    try {
      List<int> data = utf8.encode(message);

      // Check if message fits in MTU (subtract 3 bytes for BLE overhead)
      int maxDataSize = _currentMtu - 3;
      if (data.length > maxDataSize) {
        _addMessage(
          "Message too long! Max size: $maxDataSize bytes, your message: ${data.length} bytes",
          isSystem: true,
        );
        return;
      }

      // Track what we're about to send
      _lastSentData = List.from(data);
      _lastSentTime = DateTime.now();

      await _targetCharacteristic!.write(
        data,
        withoutResponse: _targetCharacteristic!.properties.writeWithoutResponse,
      );

      _addMessage("$message (${data.length} bytes)", isSent: true);
      _messageController.clear();
    } catch (e) {
      _addMessage("Send error: $e", isSystem: true);
      // Clear tracking on error
      _lastSentData = null;
      _lastSentTime = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Solari Chat', style: TextStyle(fontSize: 16)),
        backgroundColor: _isConnected ? Colors.green[100] : Colors.red[100],
        automaticallyImplyLeading: false, // Remove back button
      ),
      body: Column(
        children: [
          // Status
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(8),
            color: Colors.grey[200],
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Device: ${widget.device.platformName} | '
                    'Status: ${_isConnected ? "Connected" : "Disconnected"} | '
                    'Characteristic: ${_targetCharacteristic != null ? "Found" : "Not Found"} | '
                    'MTU: $_currentMtu bytes | '
                    'Notifications: ${_isSubscribed ? "ON" : "OFF"}',
                    style: TextStyle(fontSize: 10),
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton(
                  onPressed: (_targetCharacteristic != null && _isConnected)
                      ? (_isSubscribed
                            ? _unsubscribeFromNotifications
                            : _subscribeToNotifications)
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isSubscribed
                        ? Colors.orange[200]
                        : Colors.green[200],
                    minimumSize: Size(60, 30),
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  child: Text(
                    _isSubscribed ? 'Unsub' : 'Sub',
                    style: TextStyle(fontSize: 10),
                  ),
                ),
              ],
            ),
          ),

          // Messages List
          Expanded(
            child: Container(
              margin: EdgeInsets.all(8),
              decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  String message = _messages[index];
                  Color? backgroundColor;

                  if (message.startsWith('[SYSTEM]')) {
                    backgroundColor = Colors.orange[100];
                  } else if (message.startsWith('[SENT]')) {
                    backgroundColor = Colors.blue[100];
                  } else if (message.startsWith('[RECEIVED]')) {
                    backgroundColor = Colors.green[100];
                  }

                  return Container(
                    margin: EdgeInsets.symmetric(vertical: 2, horizontal: 8),
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: backgroundColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(message, style: TextStyle(fontSize: 10)),
                  );
                },
              ),
            ),
          ),

          // Input Area
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    style: TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      hintText: 'Type message...',
                      hintStyle: TextStyle(fontSize: 12),
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: (_targetCharacteristic != null && _isConnected)
                      ? _sendMessage
                      : null,
                  icon: Icon(Icons.send, size: 16),
                  label: Text('Send', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
