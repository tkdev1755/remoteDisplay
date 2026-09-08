import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Écoute les commandes UDP envoyées par le Mac (et par le receiver lui-même
/// sur 127.0.0.1) sur le port 5002.
///
/// Messages gérés, identiques au helper Flutter (`lib/services/udp_service.dart`) :
///   - `SLP_DETECTED`        -> mise en veille
///   - `CONN_OK`             -> réveil
///   - `BRIGHTNESS:<0-100>`  -> réglage luminosité
class UdpCommandServer {
  UdpCommandServer({
    this.port = 5002,
    required this.onSleep,
    required this.onWake,
    required this.onBrightness,
  });

  final int port;
  final void Function() onSleep;
  final void Function() onWake;
  final void Function(int percent) onBrightness;

  RawDatagramSocket? _socket;

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    stdout.writeln("📡 Helper à l'écoute sur UDP :$port");

    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _socket!.receive();
      if (dg == null) return;
      final msg = utf8.decode(dg.data, allowMalformed: true).trim();
      if (msg.isEmpty) return;
      stdout.writeln('⇦ ${dg.address.address}: $msg');
      _handle(msg);
    });
  }

  void _handle(String msg) {
    if (msg == 'SLP_DETECTED') {
      onSleep();
    } else if (msg == 'CONN_OK') {
      onWake();
    } else if (msg.startsWith('BRIGHTNESS:')) {
      final raw = msg.substring('BRIGHTNESS:'.length).trim();
      final v = int.tryParse(raw);
      if (v != null) {
        onBrightness(v.clamp(0, 100));
      } else {
        stderr.writeln('… BRIGHTNESS invalide ignoré : $msg');
      }
    } else {
      stdout.writeln('… message inconnu ignoré : $msg');
    }
  }

  void stop() => _socket?.close();
}
