import 'dart:io';
import 'package:path/path.dart' as p;

class ReceiverManager {
  Process? _process;

  // --- DÉMARRER LE RÉCEPTEPTEUR ---
  Future<void> startReceiver({bool debugMode = false}) async {
    await stopReceiver(); // Sécurité : on s'assure qu'il n'y en a pas déjà un

    String exePath = _getExecutablePath();

    if (!File(exePath).existsSync()) {
      print("❌ Erreur : L'exécutable récepteur est introuvable à $exePath");
      return;
    }

    try {
      List<String> args = debugMode ? ['--debug'] : [];

      // Lancement du processus C++
      _process = await Process.start(exePath, args);
      print("✅ Receiver lancé (PID: ${_process!.pid})");

      // Écouter les logs du C++ (stdout) si le debug est activé
      _process!.stdout.listen((data) {
        String log = String.fromCharCodes(data).trim();
        if (log.isNotEmpty) print("[C++] $log");
      });

      // Écouter les erreurs (stderr)
      _process!.stderr.listen((data) {
        String err = String.fromCharCodes(data).trim();
        if (err.isNotEmpty) print("⚠️ [C++ ERR] $err");
      });

      // Savoir quand il se ferme
      _process!.exitCode.then((code) {
        print("🛑 Receiver terminé avec le code $code");
        _process = null;
      });
    } catch (e) {
      print("❌ Impossible de lancer le receiver : $e");
    }
  }

  // --- ARRÊTER LE RÉCEPTEUR ---
  Future<void> stopReceiver() async {
    if (_process != null) {
      print("Fermeture du receiver...");
      _process!.kill(ProcessSignal.sigterm); // Envoie un signal propre
      _process = null;
    }
  }

  // --- OBTENIR LE CHEMIN DU FICHIER SELON L'OS ---
  String _getExecutablePath() {
    // Platform.resolvedExecutable donne le chemin de ton application Flutter elle-même
    String appDir = p.dirname(Platform.resolvedExecutable);

    if (Platform.isLinux) {
      // D'après notre CMakeLists.txt, on l'a mis dans data/bin/
      return p.join(appDir, 'data', 'bin', 'receiver_app');
    } else if (Platform.isMacOS) {
      // Si tu es sur Mac, Xcode met les choses dans Resources
      // Le chemin de l'app est Contents/MacOS/TonApp, donc on remonte d'un cran
      String contentsDir = p.dirname(appDir);
      return p.join(contentsDir, 'Resources', 'receiver_app');
    } else {
      throw UnsupportedError("OS non supporté");
    }
  }
}
