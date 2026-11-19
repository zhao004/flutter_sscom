import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/connection/infrastructure/tcp_server_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TCP 服务端监听单客户端并支持双向收发和断线后继续监听', () async {
    final transport = TcpServerTransport(
      bindAddress: InternetAddress.loopbackIPv4.address,
      port: 0,
    );
    Socket? client;

    try {
      await transport.open();
      expect(transport.status, TransportStatus.listening);
      final boundPort = transport.boundPort;
      expect(boundPort, isNotNull);

      final connected = transport.events.firstWhere(
        (event) => event is TransportConnectedEvent,
      );
      client = await Socket.connect(InternetAddress.loopbackIPv4, boundPort!);
      await connected.timeout(const Duration(seconds: 2));
      expect(transport.status, TransportStatus.connected);

      final received = transport.events.firstWhere(
        (event) => event is TransportDataEvent,
      );
      client.add(<int>[0x10, 0x20]);
      await client.flush();
      final dataEvent = await received.timeout(
        const Duration(seconds: 2),
      ) as TransportDataEvent;
      expect(dataEvent.bytes, orderedEquals(<int>[0x10, 0x20]));

      final clientData = Completer<Uint8List>();
      client.listen((bytes) {
        if (!clientData.isCompleted) {
          clientData.complete(Uint8List.fromList(bytes));
        }
      });
      final result = await transport.send(Uint8List.fromList(<int>[0x30]));
      expect(result.acceptedLength, 1);
      expect(
        await clientData.future.timeout(const Duration(seconds: 2)),
        orderedEquals(<int>[0x30]),
      );

      final listeningAgain = transport.events.firstWhere(
        (event) => event is TransportListeningEvent,
      );
      await client.close();
      client = null;
      await listeningAgain.timeout(const Duration(seconds: 2));
      expect(transport.status, TransportStatus.listening);

      await transport.close();
      expect(transport.status, TransportStatus.disconnected);
      final rebound = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        boundPort,
      );
      await rebound.close();
    } finally {
      client?.destroy();
      await transport.dispose();
    }
  });

  test('TCP 服务端拒绝第二个并发客户端并保留首个连接', () async {
    final transport = TcpServerTransport(
      bindAddress: InternetAddress.loopbackIPv4.address,
      port: 0,
    );
    Socket? first;
    Socket? second;
    try {
      await transport.open();
      final connected = transport.events.firstWhere(
        (event) => event is TransportConnectedEvent,
      );
      first = await Socket.connect(
        InternetAddress.loopbackIPv4,
        transport.boundPort!,
      );
      await connected.timeout(const Duration(seconds: 2));

      second = await Socket.connect(
        InternetAddress.loopbackIPv4,
        transport.boundPort!,
      );
      final firstInjected = transport.events.firstWhere(
        (event) => event is TransportDataEvent && event.bytes.single == 0x7F,
      );
      first.add(<int>[0x7F]);
      await first.flush();
      await firstInjected.timeout(const Duration(seconds: 2));
      expect(transport.status, TransportStatus.connected);
    } finally {
      first?.destroy();
      second?.destroy();
      await transport.dispose();
    }
  });
}
