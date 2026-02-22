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
  String _statusMessage = "No input detected";
  ScreenState _currentScreenState = ScreenState.active;

  Timer? _overlayTimer;
  bool _showOverlay = true;
  double _opacity = 1.0; // Contrôle l'animation de fondu

  // Variables spécifiques à la luminosité
  bool _isBrightnessMode = false;
  int _currentBrightness = 100;

  StreamSubscription? _messageSubscription;
  StreamSubscription? _stateSubscription;

  @override
  void initState() {
    super.initState();
    _startListeners();
  }

  void _startListeners() {
    // Écoute des messages bruts
    _messageSubscription = widget.udpService.messageStream.listen((message) {
      if (mounted) {
        _processMessage(message);
      }
    });

    // Écoute des changements d'état (Veille / Réveil)
    _stateSubscription = widget.udpService.stateStream.listen((state) {
      if (mounted) {
        setState(() {
          _currentScreenState = state;
          // Si on s'endort, on quitte le mode luminosité
          if (state == ScreenState.sleeping) _isBrightnessMode = false;
        });
      }
      _applyScreenState(state);
    });
  }

  void _processMessage(String message) {
    // 1. On rend l'overlay visible instantanément
    setState(() {
      _showOverlay = true;
      _opacity = 1.0;
    });
    windowManager.show();

    // 2. Traitement du message
    if (message.startsWith('BRIGHTNESS:')) {
      try {
        final valStr = message.split(':')[1];
        final val = int.parse(valStr);

        setState(() {
          _isBrightnessMode = true;
          _currentBrightness = val;
          _statusMessage = "Luminosité";
        });

        widget.systemControlService.setBrightness(val);
      } catch (e) {
        print('Message de luminosité invalide : $message');
      }
    } else {
      setState(() {
        _isBrightnessMode = false;
        if (message == 'SLP_DETECTED') {
          _statusMessage = "Going to sleep...";
        } else if (message == 'CONN_OK') {
          _statusMessage = "Connected";
        } else {
          _statusMessage = message;
        }
      });
    }

    // 3. Relance du timer pour masquer l'overlay
    _handleOverlayTimer();
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

    // Masquer l'overlay après 3 secondes d'inactivité
    _overlayTimer = Timer(const Duration(seconds: 3), () {
      if (_currentScreenState == ScreenState.active && mounted) {
        // Déclenche l'animation de fondu
        setState(() {
          _opacity = 0.0;
        });

        // Attend la fin de l'animation (300ms) avant de cacher la fenêtre à l'OS
        Future.delayed(const Duration(milliseconds: 300), () async {
          if (mounted && _opacity == 0.0) {
            setState(() {
              _showOverlay = false;
            });
            await windowManager.hide();
          }
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Si l'overlay est caché et l'écran actif, on ne dessine rien
    if (!_showOverlay && _currentScreenState == ScreenState.active) {
      return const SizedBox.shrink();
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 300),
          opacity: _opacity,
          child: Container(
            width: 220, // Largeur fixe pour éviter les sauts d'interface
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(72), // Fond un peu plus sombre style macOS
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(20)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(60),
                  blurRadius: 15,
                  spreadRadius: 5,
                )
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // --- ICÔNE ANIMÉE ---
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (Widget child, Animation<double> animation) {
                    return ScaleTransition(scale: animation, child: child);
                  },
                  child: Icon(
                    _isBrightnessMode ? Icons.light_mode : Icons.monitor,
                    key: ValueKey<bool>(_isBrightnessMode),
                    color: Colors.white,
                    size: 48,
                  ),
                ),

                const SizedBox(height: 16),

                // --- TEXTE ---
                Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),

                // --- BARRE DE LUMINOSITÉ (S'affiche uniquement en mode brightness) ---
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: _isBrightnessMode
                      ? Column(
                    children: [
                      const SizedBox(height: 12),
                      _buildBrightnessBar(),
                      const SizedBox(height: 8),
                      Text(
                        "$_currentBrightness %",
                        style: TextStyle(
                          color: Colors.white.withAlpha(120),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  )
                      : const SizedBox.shrink(), // Vide si on est pas en mode luminosité
                ),

                if (_currentScreenState == ScreenState.sleeping)
                  const Padding(
                    padding: EdgeInsets.only(top: 8.0),
                    child: Text(
                      "Sleeping",
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- WIDGET : LA BARRE DE PROGRESSION ANIMÉE ---
  Widget _buildBrightnessBar() {
    return Container(
      height: 12,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(100),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Align(
            alignment: Alignment.centerLeft,
            child: AnimatedContainer(
              // L'animation élastique quand la barre se remplit/se vide
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              width: constraints.maxWidth * (_currentBrightness / 100.0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          );
        },
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