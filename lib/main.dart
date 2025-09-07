import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'screens/bluetooth_off_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/solari_screen.dart';

void main() {
  FlutterBluePlus.setLogLevel(LogLevel.verbose, color: true);
  runApp(const SolariApp());
}

// Solari Application main widget
class SolariApp extends StatefulWidget {
  const SolariApp({Key? key}) : super(key: key);

  @override
  State<SolariApp> createState() => _SolariAppState();
}

// This class is the state class for the SolariApp widget that monitors the device's Bluetooth state and updates the UI. It shows ScanScreen if Bluetooth is on, otherwise BluetoothOffScreen. It listens for changes with a stream subscription and cleans up when the widget is removed.
class _SolariAppState extends State<SolariApp> {
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  BluetoothDevice? _connectedSolariDevice;

  late StreamSubscription<BluetoothAdapterState> _adapterStateStateSubscription;

  // Solari service UUID to identify Solari devices
  final String _solariServiceUUID = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';

  // Initialize state and start listening to Bluetooth state changes
  @override
  void initState() {
    super.initState();
    _adapterStateStateSubscription = FlutterBluePlus.adapterState.listen((
      state,
    ) {
      _adapterState = state;
      if (mounted) {
        setState(() {});
      }
    });

    // Check for already connected Solari devices
    _checkForConnectedSolariDevice();
  }

  // Clean up the subscription when the widget is disposed
  @override
  void dispose() {
    _adapterStateStateSubscription.cancel();
    super.dispose();
  }

  // Check if there's already a connected Solari device
  void _checkForConnectedSolariDevice() async {
    List<BluetoothDevice> connectedDevices = FlutterBluePlus.connectedDevices;

    for (BluetoothDevice device in connectedDevices) {
      if (device.isConnected) {
        try {
          // Discover services to check for Solari service UUID
          List<BluetoothService> services = await device.discoverServices();
          bool hasSolariService = services.any(
            (service) =>
                service.uuid.str.toLowerCase() ==
                _solariServiceUUID.toLowerCase(),
          );

          if (hasSolariService) {
            setState(() {
              _connectedSolariDevice = device;
            });
            break;
          }
        } catch (e) {
          // If we can't discover services, skip this device
          continue;
        }
      }
    }
  }

  // Build the UI based on the current Bluetooth state and connection status
  @override
  Widget build(BuildContext context) {
    Widget screen;

    if (_adapterState != BluetoothAdapterState.on) {
      // Show BluetoothOffScreen if Bluetooth is off
      screen = BluetoothOffScreen(adapterState: _adapterState);
    } else if (_connectedSolariDevice != null) {
      // Show SolariScreen if connected to a Solari device
      screen = SolariScreen(device: _connectedSolariDevice!);
    } else {
      // Show ScanScreen if Bluetooth is on but not connected to Solari
      screen = const ScanScreen();
    }

    return MaterialApp(
      title: 'Solari',
      home: screen,
      navigatorObservers: [BluetoothAdapterStateObserver()],
    );
  }
}

// This class ensures the app reacts immediately to Bluetooth turning off while connected to a device, without keeping listeners active unnecessarily.
class BluetoothAdapterStateObserver extends NavigatorObserver {
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;

  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    if (route.settings.name == '/SolariScreen') {
      // Start listening to Bluetooth state changes when connected to smart glasses
      _adapterStateSubscription ??= FlutterBluePlus.adapterState.listen((
        state,
      ) {
        if (state != BluetoothAdapterState.on) {
          // Disconnect from smart glasses if Bluetooth is off
          navigator?.pop();
        }
      });
    }
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    // Cancel the subscription when disconnecting from smart glasses
    _adapterStateSubscription?.cancel();
    _adapterStateSubscription = null;
  }
}
