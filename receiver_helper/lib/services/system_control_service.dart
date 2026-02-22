import 'dart:io';

import 'receiver_manager.dart';

class SystemControlService {
  ReceiverManager recvManager;
  bool isSleeping = false;
  SystemControlService(this.recvManager);

  Future<void> sleepScreen() async {
    try {
      // Try xset (X11)
      print('Screen sleep command sent (xset)');
      if (!isSleeping){
        await Process.run('xrandr', ['--output', 'eDP', '--off']);        isSleeping = true;
        await recvManager.suspendReceiver();
      }
    } catch (e) {
      print('Error executing sleep command: $e');
    }
  }

  Future<void> wakeScreen() async {
    try {
      // Try xset (X11)
      print('Screen wake command received (xset)');
      if (isSleeping){
        await Process.run('xrandr', ['--output', 'eDP', '--auto']);
        isSleeping = false;
        await recvManager.resumeReceiver();
      }
    } catch (e) {
      print('Error executing wake command: $e');
    }
  }

  Future<void> setBrightness(int brightness) async {
    // Brightness is expected to be 0-100
    try {
      // Try brightnessctl (needs to be installed)
      // brightnessctl s 50%
      await Process.run('brightnessctl', ['s', '$brightness%']);
      print('Brightness set to $brightness% via brightnessctl');
    } catch (e) {
      print('Error setting brightness: $e');
      // Fallback or other methods could be added here (e.g. ddcutil)
    }
  }
}
