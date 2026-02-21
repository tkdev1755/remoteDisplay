import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'services/udp_service.dart';
import 'services/system_control_service.dart';
import 'ui/overlay_widget.dart';
import "services/receiver_manager.dart";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final receiverManager = ReceiverManager();

  receiverManager.startReceiver();
  WindowOptions windowOptions = const WindowOptions(
    size: Size(400, 200),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
    // For overlay, we effectively want to cover the screen or be a floating widget.
    // Here we start centered.
    // If full screen overlay is desired, uncomment:
    // await windowManager.setFullScreen(true);
  });

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final UDPService _udpService = UDPService();
  final SystemControlService _systemControlService = SystemControlService();

  @override
  void initState() {
    super.initState();
    _udpService.start();
  }

  @override
  void dispose() {
    _udpService.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Receiver Helper',
      theme: ThemeData(
        visualDensity: VisualDensity.adaptivePlatformDensity,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: OverlayWidget(
        udpService: _udpService,
        systemControlService: _systemControlService,
      ),
    );
  }
}
