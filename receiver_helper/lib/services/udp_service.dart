import 'dart:io';
import 'dart:convert';
import 'dart:async';

enum ScreenState {
  active,
  sleeping,
}

class UDPService {
  RawDatagramSocket? _socket;
  final StreamController<String> _messageController = StreamController<String>.broadcast();
  final StreamController<ScreenState> _stateController = StreamController<ScreenState>.broadcast();
  final int port;

  UDPService({this.port = 5002});

  Stream<String> get messageStream => _messageController.stream;
  Stream<ScreenState> get stateStream => _stateController.stream;

  Future<void> start() async {
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
      print('UDP Receiver Helper listening on port $port');

      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _socket!.receive();
          if (dg != null) {
            String message = utf8.decode(dg.data).trim();
            print('Received UDP: $message');
            _handleMessage(message);
            _messageController.add(message);
          }
        }
      });
    } catch (e) {
      print('Error binding UDP port $port: $e');
    }
  }

  void _handleMessage(String message) {
    if (message == 'SLP_DETECTED') {
      _stateController.add(ScreenState.sleeping);
    } else if (message == 'CONN_OK') {
      _stateController.add(ScreenState.active);
    }
    // Brightness parsing can be done by the UI or another handler if needed,
    // but the raw message is also exposed.
  }

  void stop() {
    _socket?.close();
    _messageController.close();
    _stateController.close();
  }
}
