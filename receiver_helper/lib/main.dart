import 'package:flutter/material.dart';
import 'package:flutter_acrylic/window.dart';
import 'package:flutter_acrylic/window_effect.dart';
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
    size: Size(200, 200),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.setAsFrameless();
    await windowManager.focus();
    await windowManager.setHasShadow(false);
    // For overlay, we effectively want to cover the screen or be a floating widget.
    // Here we start centered.
    // If full screen overlay is desired, uncomment:
    // await windowManager.setFullScreen(true);
  });

  runApp(MyApp(recvManager: receiverManager));
}

class MyApp extends StatefulWidget {
  ReceiverManager recvManager;
  MyApp({super.key, required this.recvManager});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final UDPService _udpService = UDPService();
  late final SystemControlService _systemControlService = SystemControlService(
    widget.recvManager,
  );

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
      color: Colors.transparent,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.transparent,
        useMaterial3: true,
      ),
      home: OverlayWidget(
        udpService: _udpService,
        systemControlService: _systemControlService,
      ),
    );
  }
}
