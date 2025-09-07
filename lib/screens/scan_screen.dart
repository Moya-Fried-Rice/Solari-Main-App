import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../utils/snackbar.dart';
import '../utils/extra.dart';
import 'solari_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

// This class displays a screen to scan for Solari Smart Glasses using Bluetooth. It shows an icon, the current scanning status, and buttons to connect to the device or rescan. It uses streams to listen for scan results and updates the UI accordingly.
class _ScanScreenState extends State<ScanScreen> {
  BluetoothDevice? _solariDevice;
  bool _isScanning = false;
  late StreamSubscription<List<ScanResult>> _scanResultsSubscription;
  late StreamSubscription<bool> _isScanningSubscription;

  // Solari service UUID
  final String _solariServiceUUID = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';

  // Initialize state and start scanning for Solari devices
  @override
  void initState() {
    super.initState();

    _scanResultsSubscription = FlutterBluePlus.scanResults.listen(
      (results) {
        if (mounted) {
          // Look for the Solari Smart Glasses device
          for (ScanResult result in results) {
            if (result.advertisementData.serviceUuids.any(
              (uuid) =>
                  uuid.str.toLowerCase() == _solariServiceUUID.toLowerCase(),
            )) {
              setState(() => _solariDevice = result.device);
              // Stop scanning once device is found
              _stopScan();
              break;
            }
          }
        }
      },
      onError: (e) {
        Snackbar.show(
          ABC.b,
          prettyException("Smart Glasses Scan Error:", e),
          success: false,
        );
      },
    );

    _isScanningSubscription = FlutterBluePlus.isScanning.listen((state) {
      if (mounted) {
        setState(() => _isScanning = state);
      }
    });

    // Start scanning automatically
    _startSolariDeviceScan();
  }

  // Clean up subscriptions when the widget is disposed
  @override
  void dispose() {
    _scanResultsSubscription.cancel();
    _isScanningSubscription.cancel();
    super.dispose();
  }

  // Start scanning for Solari devices
  Future _startSolariDeviceScan() async {
    try {
      // Reset device state when starting new scan
      setState(() => _solariDevice = null);

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        withServices: [Guid(_solariServiceUUID)],
      );
    } catch (e, backtrace) {
      Snackbar.show(
        ABC.b,
        prettyException("Solari Device Scan Error:", e),
        success: false,
      );
      print(e);
      print("backtrace: $backtrace");
    }
  }

  // Stop scanning for devices
  Future _stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (e, backtrace) {
      Snackbar.show(
        ABC.b,
        prettyException("Stop Scan Error:", e),
        success: false,
      );
      print(e);
      print("backtrace: $backtrace");
    }
  }

  // Handle connect button press
  void onConnectPressed(BluetoothDevice device) {
    device
        .connectAndUpdateStream()
        .catchError((e) {
          Snackbar.show(
            ABC.c,
            prettyException("Connect Error:", e),
            success: false,
          );
        })
        .then((_) {
          // Navigate to Solari screen after successful connection
          MaterialPageRoute route = MaterialPageRoute(
            builder: (context) => SolariScreen(device: device),
            settings: const RouteSettings(name: '/SolariScreen'),
          );
          Navigator.of(context).push(route);
        });
  }

  // Solari glasses icon
  Widget buildSolariIcon(BuildContext context) {
    return Icon(
      _solariDevice != null ? Icons.visibility : Icons.search,
      size: 128,
      color: _solariDevice != null ? Colors.green : Colors.grey,
    );
  }

  // Title indicating device status
  Widget buildTitle(BuildContext context) {
    String status;
    if (_isScanning) {
      status = 'Scanning for Solari Smart Glasses...';
    } else if (_solariDevice != null) {
      status = 'Device Found!';
    } else {
      status = 'No Solari Smart Glasses Found';
    }

    return Column(
      children: [
        Text(
          status,
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        if (_solariDevice != null)
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Text(
              'Solari Smart Glasses Ready',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }

  // Connect button
  Widget buildConnectButton(BuildContext context) {
    return TextButton(
      onPressed: _solariDevice != null
          ? () => onConnectPressed(_solariDevice!)
          : null,
      child: const Text('Connect to Solari'),
    );
  }

  // Scan button
  Widget buildScanButton(BuildContext context) {
    return TextButton(
      onPressed: _isScanning ? null : _startSolariDeviceScan,
      child: Text(_isScanning ? 'Scanning...' : 'Scan Again'),
    );
  }

  // Build the main UI
  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: Snackbar.snackBarKeyB,
      child: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              buildSolariIcon(context),
              const SizedBox(height: 24),
              buildTitle(context),
              const SizedBox(height: 24),
              if (_solariDevice != null) buildConnectButton(context),
              const SizedBox(height: 16),
              buildScanButton(context),
            ],
          ),
        ),
      ),
    );
  }
}
