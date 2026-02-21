import 'dart:async';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../services/udp_service.dart';
import '../services/system_control_service.dart';

class OverlayWidget extends StatefulWidget {
  final UDPService udpService;
  final SystemControlService systemControlService;

  const OverlayWidget({
    super.key,
    required this.udpService,
    required this.systemControlService,
  });

  @override
  State<OverlayWidget> createState() => _OverlayWidgetState();
}

class _OverlayWidgetState extends State<OverlayWidget> {
  String _statusMessage = "Waiting for connection...";
  ScreenState _currentScreenState = ScreenState.active;
  Timer? _overlayTimer;
  bool _showOverlay = true;
  StreamSubscription? _messageSubscription;
  StreamSubscription? _stateSubscription;

  @override
  void initState() {
    super.initState();
    _startListeners();
  }

  void _startListeners() {
    // Listen for raw messages
    _messageSubscription = widget.udpService.messageStream.listen((message) {
      if (mounted) {
        setState(() {
          _statusMessage = _parseMessage(message);
          _showOverlay = true;
        });
        windowManager.show();
        _handleOverlayTimer();
      }
      _processControlMessage(message);
    });

    // Listen for state changes
    _stateSubscription = widget.udpService.stateStream.listen((state) {
      if (mounted) {
        setState(() {
          _currentScreenState = state;
        });
      }
      _applyScreenState(state);
    });
  }

  String _parseMessage(String message) {
    if (message == 'SLP_DETECTED') return "Sleeping...";
    if (message == 'CONN_OK') return "Connected";
    if (message.startsWith('BRIGHTNESS')) return "Brightness Updated";
    return message; // Display raw message for other cases
  }

  void _processControlMessage(String message) {
    if (message.startsWith('BRIGHTNESS:')) {
      // Format: BRIGHTNESS:50
      try {
        final valStr = message.split(':')[1];
        final val = int.parse(valStr);
        widget.systemControlService.setBrightness(val);
      } catch (e) {
        print('Invalid brightness message: $message');
      }
    }
  }

  void _applyScreenState(ScreenState state) {
    if (state == ScreenState.sleeping) {
      widget.systemControlService.sleepScreen();
    } else if (state == ScreenState.active) {
      widget.systemControlService.wakeScreen();
    }
  }

  void _handleOverlayTimer() {
    _overlayTimer?.cancel();
    // Hide overlay after 3 seconds of inactivity if connected
    _overlayTimer = Timer(const Duration(seconds: 3), () {
      if (_currentScreenState == ScreenState.active && mounted) {
        setState(() {
          _showOverlay = false;
        });
        windowManager.hide();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_showOverlay && _currentScreenState == ScreenState.active) {
      return const SizedBox.shrink();
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.2)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.monitor, color: Colors.white, size: 48),
              const SizedBox(height: 16),
              Text(
                _statusMessage,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (_currentScreenState == ScreenState.sleeping)
                const Padding(
                  padding: EdgeInsets.only(top: 8.0),
                  child: Text(
                    "Display Sleep Mode",
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    _messageSubscription?.cancel();
    _stateSubscription?.cancel();
    super.dispose();
  }
}
