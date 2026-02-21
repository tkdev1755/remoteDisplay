import 'dart:io';

class SystemControlService {
  Future<void> sleepScreen() async {
    try {
      // Try xset (X11)
      await Process.run('xset', ['dpms', 'force', 'off']);
      print('Screen sleep command sent (xset)');
    } catch (e) {
      print('Error executing sleep command: $e');
    }
  }

  Future<void> wakeScreen() async {
    try {
      // Try xset (X11)
      await Process.run('xset', ['dpms', 'force', 'on']);
      print('Screen wake command sent (xset)');
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
