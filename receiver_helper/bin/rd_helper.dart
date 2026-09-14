import 'dart:async';
import 'dart:io';

import 'package:rd_helper/receiver_manager.dart';
import 'package:rd_helper/system_control_service.dart';
import 'package:rd_helper/udp_command_server.dart';

const _usage = '''
rd_helper — helper headless du récepteur remoteDisplay (KMS/DRM)

Usage :
  rd_helper [options] [-- <args passés au receiver>]

Options :
  --receiver <path>   Chemin de l'exécutable receiver
                      (déf. : \$RD_RECEIVER_BIN, sinon recherche automatique)
  --port <n>          Port UDP d'écoute des commandes (déf. : \$RD_PORT ou 5002)
  --no-debug          Ne pas passer --debug au receiver
  -h, --help          Affiche cette aide

Exemple :
  rd_helper --receiver /opt/remotedisplay/receiver_app -- --width 3840 --height 2160
''';

class _Opts {
  String receiverPath = '';
  int port = 5002;
  bool debug = true;
  List<String> receiverArgs = const [];
}

_Opts _parseArgs(List<String> argv) {
  final o = _Opts()
    ..port = int.tryParse(Platform.environment['RD_PORT'] ?? '') ?? 5002;
  String? cliReceiver;

  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--') {
      o.receiverArgs = argv.sublist(i + 1);
      break;
    } else if (a == '-h' || a == '--help') {
      stdout.write(_usage);
      exit(0);
    } else if (a == '--no-debug') {
      o.debug = false;
    } else if (a == '--receiver' && i + 1 < argv.length) {
      cliReceiver = argv[++i];
    } else if (a == '--port' && i + 1 < argv.length) {
      o.port = int.tryParse(argv[++i]) ?? o.port;
    } else {
      stderr.writeln('Option inconnue : $a\n');
      stdout.write(_usage);
      exit(2);
    }
  }

  o.receiverPath = _resolveReceiver(cliReceiver);
  return o;
}

/// Résout le chemin du binaire receiver : argument > env > emplacements connus.
String _resolveReceiver(String? cli) {
  final candidates = <String>[
    if (cli != null) cli,
    if (Platform.environment['RD_RECEIVER_BIN'] != null)
      Platform.environment['RD_RECEIVER_BIN']!,
  ];

  final selfDir = File(Platform.resolvedExecutable).parent.path;
  for (final name in const ['receiver_app', 'receiver']) {
    candidates
      ..add('$selfDir/$name')
      ..add('/opt/remotedisplay/$name')
      ..add('/usr/local/bin/$name');
  }

  for (final c in candidates) {
    if (c.isNotEmpty && File(c).existsSync()) return c;
  }
  // Rien trouvé : on renvoie le 1er candidat pour un message d'erreur parlant.
  return candidates.isNotEmpty ? candidates.first : 'receiver_app';
}

Future<void> main(List<String> argv) async {
  final opts = _parseArgs(argv);

  final receiver = ReceiverManager(
    executablePath: opts.receiverPath,
    debugMode: opts.debug,
    extraArgs: opts.receiverArgs,
  );
  final sys = SystemControlService(receiver);
  final udp = UdpCommandServer(
    port: opts.port,
    onSleep: sys.sleepScreen,
    onWake: sys.wakeScreen,
    onBrightness: sys.setBrightness,
  );

  var shuttingDown = false;
  Future<void> shutdown(ProcessSignal s) async {
    if (shuttingDown) return;
    shuttingDown = true;
    stdout.writeln('\n⏹  Signal $s — arrêt du helper…');
    udp.stop();
    await receiver.stop();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  ProcessSignal.sigterm.watch().listen(shutdown);

  await udp.start();
  await receiver.start();
  stdout.writeln(
      '🟢 Helper prêt — receiver=${opts.receiverPath} port=${opts.port}');
}
