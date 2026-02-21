import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:receiver_helper/services/udp_service.dart';

void main() {
  group('UDPService Tests', () {
    late UDPService udpService;

    setUp(() async {
      // Use a different port for testing to avoid conflicts
      udpService = UDPService(port: 5003);
      await udpService.start();
    });

    tearDown(() {
      udpService.stop();
    });

    test('Should parse SLP_DETECTED and emit sleeping state', () async {
      // Create a sender socket
      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      
      // Expectation
      final stateFuture = udpService.stateStream.first;
      final messageFuture = udpService.messageStream.first;

      // Send packet
      sender.send('SLP_DETECTED'.codeUnits, InternetAddress.loopbackIPv4, 5003);

      // Verify
      expect(await stateFuture, equals(ScreenState.sleeping));
      expect(await messageFuture, equals('SLP_DETECTED'));

      sender.close();
    });

    test('Should parse CONN_OK and emit active state', () async {
      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      
      final stateFuture = udpService.stateStream.first;

      sender.send('CONN_OK'.codeUnits, InternetAddress.loopbackIPv4, 5003);

      expect(await stateFuture, equals(ScreenState.active));

      sender.close();
    });
  });
}
