import 'dart:io';
import 'package:path/path.dart' as p;

class ReceiverManager {
  Process? _process;
  bool is_suspended = false;
  // --- DÉMARRER LE RÉCEPTEPTEUR ---
  Future<void> startReceiver({bool debugMode = true}) async {
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

  Future<void> resumeReceiver() async {
    if (_process == null) {
      print("⚠️ Aucun processus à reprendre. Démarrage initial...");
      await startReceiver();
      return;
    }

    // S'il est bien en pause, on le réveille
    if (is_suspended) {
      print("▶️ Réveil du receiver (SIGCONT)...");
      _process!.kill(ProcessSignal.sigcont);
      is_suspended = false;
    } else {
      print("ℹ️ Le receiver est déjà actif et n'est pas en pause.");
    }
  }

  // --- ARRÊTER LE RÉCEPTEUR ---
  Future<void> stopReceiver() async {
    if (_process != null) {
      print("Fermeture du receiver...");
      await _process!.kill(ProcessSignal.sigterm); // Envoie un signal propre

      try {
        // 2. LA CLÉ EST ICI : On attend que Linux confirme la fermeture du port (max 2 secondes)
        await _process?.exitCode.timeout(const Duration(seconds: 2));
        print("✅ Receiver fermé proprement.");
      } catch (e) {
        // 3. S'il met plus de 2 secondes, on le tue violemment pour libérer le port UDP
        print("⚠️ Le receiver met trop de temps, exécution d'un SIGKILL...");
        _process?.kill(ProcessSignal.sigkill);
        await _process?.exitCode; // On attend la confirmation du kill forcé
        print("💀 Receiver forcé à quitter.");
      }
      _process = null;
    }
  }
  Future<void> suspendReceiver() async {
    if (_process != null && !is_suspended) {
      print("⏸️ Mise en pause du receiver (SIGSTOP)...");
      _process!.kill(ProcessSignal.sigstop);
      print("suspend exit code = $exitCode");
      is_suspended = true;
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
