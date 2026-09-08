import 'dart:io';

import 'receiver_manager.dart';

/// Pilotage de l'écran sans serveur X (KMS/DRM).
///
/// Équivalent de `lib/services/system_control_service.dart` du helper Flutter,
/// mais `xrandr` n'existe pas ici.
///
/// **Extinction / rallumage** : sur cet iMac, `amdgpu` ignore `bl_power` et la
/// dalle garde un plancher de rétroéclairage — `brightness 0` assombrit sans
/// éteindre. Le seul vrai DPMS off accessible est celui de `drm_fb_helper` :
/// une fois le receiver arrêté (DRM master libéré), `amdgpudrmfb` reprend la
/// main et `echo 4 > /sys/class/graphics/fbN/blank` coupe réellement le
/// panneau + le rétroéclairage.
///
/// **Luminosité** : `brightnessctl`, repli sur écriture directe dans
/// `/sys/class/backlight`.
class SystemControlService {
  SystemControlService(this.receiver);

  final ReceiverManager receiver;

  bool _sleeping = false;
  int _lastBrightness = 100;
  String? _backlightDir;
  bool _backlightResolved = false;

  // --- EXTINCTION / RALLUMAGE ------------------------------------------------

  Future<void> sleepScreen() async {
    if (_sleeping) return;
    _sleeping = true;
    stdout.writeln("🌙 Extinction de l'écran");
    // Arrêt du receiver -> DRM master libéré -> amdgpudrmfb reprend la main,
    // ce qui rend fbX/blank effectif juste après.
    await receiver.stop();
    await _fbBlank(true); // DPMS off réel (drm_fb_helper)
  }

  Future<void> wakeScreen() async {
    if (!_sleeping) {
      // CONN_OK reçu hors veille : on garantit juste que le receiver tourne.
      if (!receiver.isRunning) await receiver.start();
      return;
    }
    _sleeping = false;
    stdout.writeln("☀️ Rallumage de l'écran");
    await _fbBlank(false);
    await receiver.start(); // reprend le DRM master + refait le modeset
    // Un cycle DPMS off/on peut réinitialiser le niveau : on réapplique.
    await _setBacklightPercent(_lastBrightness);
  }

  // --- LUMINOSITÉ ----------------------------------------------------------

  Future<void> setBrightness(int percent) async {
    percent = percent.clamp(0, 100);
    _lastBrightness = percent;
    if (_sleeping) return; // sera réappliqué au réveil
    await _setBacklightPercent(percent, verbose: true);
  }

  Future<void> _setBacklightPercent(int percent, {bool verbose = false}) async {
    // 1) brightnessctl (fonctionne sans X)
    try {
      final r = await Process.run('brightnessctl', ['-q', 's', '$percent%']);
      if (r.exitCode == 0) {
        if (verbose) stdout.writeln('🔆 Luminosité $percent% (brightnessctl)');
        return;
      }
    } catch (_) {
      // binaire absent -> on tente le sysfs
    }

    // 2) écriture directe dans /sys/class/backlight
    final dir = _resolveBacklight();
    if (dir == null) {
      if (verbose) {
        stderr.writeln('⚠️ Aucun périphérique de rétroéclairage : '
            'réglage de luminosité impossible sur cette dalle.');
      }
      return;
    }
    try {
      final max =
          int.parse(File('$dir/max_brightness').readAsStringSync().trim());
      final val = (max * percent / 100).round();
      File('$dir/brightness').writeAsStringSync('$val');
      if (verbose) stdout.writeln('🔆 Luminosité $percent% (sysfs $val/$max)');
    } catch (e) {
      if (verbose) {
        stderr.writeln('⚠️ Écriture $dir/brightness impossible : $e '
            '(le helper doit tourner en root).');
      }
    }
  }

  String? _resolveBacklight() {
    if (_backlightResolved) return _backlightDir;
    _backlightResolved = true;
    final d = Directory('/sys/class/backlight');
    if (d.existsSync()) {
      final entries = d.listSync();
      if (entries.isNotEmpty) {
        _backlightDir = entries.first.path;
        stdout.writeln('💡 Rétroéclairage : $_backlightDir');
      }
    }
    if (_backlightDir == null) {
      stderr.writeln(
          '⚠️ /sys/class/backlight vide — pas de contrôle de luminosité.');
    }
    return _backlightDir;
  }

  // --- FRAMEBUFFER CONSOLE --------------------------------------------------

  /// Éteint (`true`, FB_BLANK_POWERDOWN) ou rallume (`false`, FB_BLANK_UNBLANK)
  /// le panneau via l'émulation fbdev d'amdgpu.
  ///
  /// N'a d'effet que si `amdgpudrmfb` tient l'écran : à appeler seulement une
  /// fois le receiver arrêté. On réessaie quelques fois, le temps que le fbcon
  /// reprenne la main après la libération du DRM master.
  Future<void> _fbBlank(bool blank) async {
    final value = blank ? '4' : '0';
    var ok = false;
    for (var attempt = 0; attempt < 6 && !ok; attempt++) {
      for (final path in const [
        '/sys/class/graphics/fb0/blank',
        '/sys/class/graphics/fb1/blank',
      ]) {
        final f = File(path);
        if (!f.existsSync()) continue;
        try {
          f.writeAsStringSync(value);
          ok = true;
        } catch (_) {
          // fbcon n'a pas encore repris la main
        }
      }
      if (!ok) await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (!ok) {
      stderr.writeln("⚠️ Écriture fbX/blank impossible "
          "(helper non-root, ou aucun /sys/class/graphics/fbN/blank).");
    }
  }
}
