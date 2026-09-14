import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Lance et supervise le process C++ `receiver_app`.
///
/// Équivalent headless de `lib/services/receiver_manager.dart` du helper Flutter :
/// start / stop / suspend (SIGSTOP) / resume (SIGCONT), avec redémarrage
/// automatique si le process meurt sans qu'on le lui ait demandé.
class ReceiverManager {
  ReceiverManager({
    required this.executablePath,
    this.debugMode = true,
    this.extraArgs = const <String>[],
  });

  final String executablePath;
  final bool debugMode;
  final List<String> extraArgs;

  Process? _process;
  bool _suspended = false;
  bool _stopping = false;
  Timer? _restartTimer;

  bool get isRunning => _process != null;
  bool get isSuspended => _suspended;

  Future<void> start() async {
    _restartTimer?.cancel();
    await stop();
    _stopping = false;

    if (!File(executablePath).existsSync()) {
      stderr.writeln('❌ Exécutable receiver introuvable : $executablePath');
      return;
    }

    final args = <String>[
      if (debugMode) '--debug',
      ...extraArgs,
    ];

    try {
      _process = await Process.start(executablePath, args);
      _suspended = false;
      stdout.writeln(
          '✅ Receiver lancé (PID ${_process!.pid}) : $executablePath ${args.join(' ')}');

      _pipe(_process!.stdout, '[recv] ', stdout);
      _pipe(_process!.stderr, '[recv!] ', stderr);

      unawaited(_process!.exitCode.then((code) {
        stdout.writeln('🛑 Receiver terminé (code $code)');
        final wasIntentional = _stopping;
        _process = null;
        _suspended = false;
        if (!wasIntentional) {
          stdout.writeln('↻ Redémarrage du receiver dans 2 s…');
          _restartTimer = Timer(const Duration(seconds: 2), () {
            if (_process == null) start();
          });
        }
      }));
    } catch (e) {
      stderr.writeln('❌ Lancement receiver impossible : $e');
    }
  }

  Future<void> stop() async {
    _restartTimer?.cancel();
    final p = _process;
    if (p == null) return;
    _stopping = true;

    // Un process stoppé (SIGSTOP) ne traitera pas SIGTERM : on le réveille d'abord.
    if (_suspended) {
      p.kill(ProcessSignal.sigcont);
      _suspended = false;
    }

    stdout.writeln('… Arrêt du receiver (SIGTERM)');
    p.kill(ProcessSignal.sigterm);
    try {
      await p.exitCode.timeout(const Duration(seconds: 2));
      stdout.writeln('✅ Receiver arrêté proprement');
    } on TimeoutException {
      stdout.writeln('⚠️ Timeout → SIGKILL (libération du port UDP)');
      p.kill(ProcessSignal.sigkill);
      await p.exitCode;
    }
    _process = null;
    _suspended = false;
  }

  void suspend() {
    final p = _process;
    if (p != null && !_suspended) {
      stdout.writeln('⏸️  Receiver en pause (SIGSTOP)');
      p.kill(ProcessSignal.sigstop);
      _suspended = true;
    }
  }

  Future<void> resume() async {
    final p = _process;
    if (p == null) {
      await start();
      return;
    }
    if (_suspended) {
      stdout.writeln('▶️  Reprise du receiver (SIGCONT)');
      p.kill(ProcessSignal.sigcont);
      _suspended = false;
    }
  }

  void _pipe(Stream<List<int>> src, String prefix, IOSink dst) {
    src
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isNotEmpty) dst.writeln('$prefix$line');
    });
  }
}
