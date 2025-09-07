import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../utils/snackbar.dart';

// This class displays a screen when Bluetooth is off. It shows a Bluetooth-off icon, a message with the current Bluetooth state, and a button to enable Bluetooth on Android devices.
class BluetoothOffScreen extends StatelessWidget {
  const BluetoothOffScreen({super.key, this.adapterState});

  final BluetoothAdapterState? adapterState;

  // Bluetooth off icon
  Widget buildBluetoothOffIcon(BuildContext context) {
    return Icon(
      Icons.bluetooth_disabled,
      size: 128,
      color: Colors.grey,
    );
  }

  // Title indicating Bluetooth is off
  Widget buildTitle(BuildContext context) {
    String? state = adapterState?.toString().split(".").last;
    return Column(
      children: [
        Text('Bluetooth is ${state ?? 'not available'}'),
      ],
    );
  }

  // Button to turn on Bluetooth (Android only)
  Widget buildTurnOnButton(BuildContext context) {
    return TextButton(
      child: const Text('Enable Bluetooth'),
      onPressed: () async {
        try {
          if (!kIsWeb && Platform.isAndroid) {
            await FlutterBluePlus.turnOn();
          }
        } catch (e, backtrace) {
          Snackbar.show(
            ABC.a,
            prettyException("Error Turning On:", e),
            success: false,
          );
          print("$e");
          print("backtrace: $backtrace");
        }
      },
    );
  }

  // Build the main UI
  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: Snackbar.snackBarKeyA,
      child: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              buildBluetoothOffIcon(context),
              buildTitle(context),
              if (!kIsWeb && Platform.isAndroid) buildTurnOnButton(context),
            ],
          ),
        ),
      ),
    );
  }
}
