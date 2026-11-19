import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/connection/infrastructure/udp_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UDP 保留数据报边界并跟随最近来源更新发送目标', () async {
    final receiverA = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final receiverB = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final transport = UdpTransport(
      bindAddress: InternetAddress.loopbackIPv4.address,
      localPort: 0,
      remoteHost: InternetAddress.loopbackIPv4.address,
      remotePort: receiverA.port,
      followRemoteEndpoint: true,
    );

    try {
      await transport.open();
      expect(transport.status, TransportStatus.connected);
      final boundPort = transport.boundPort!;
      final datagramToA = _nextDatagram(receiverA);
      await transport.send(Uint8List.fromList(<int>[1, 2, 3]));
      expect(
        (await datagramToA.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException('未收到发送到默认远端的 UDP 数据'),
        )).data,
        orderedEquals(<int>[1, 2, 3]),
      );

      final followedSource = transport.events.firstWhere(
        (event) =>
            event is TransportDataEvent &&
            event.bytes.length == 1 &&
            event.bytes.single == 9,
      );
      receiverB.send(
        <int>[9],
        InternetAddress.loopbackIPv4,
        transport.boundPort!,
      );
      await followedSource.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw TimeoutException('未跟随最近 UDP 来源'),
      );
      expect(transport.currentRemotePort, receiverB.port);

      final datagramToB = _nextDatagram(receiverB);
      await transport.send(Uint8List.fromList(<int>[4, 5]));
      expect(
        (await datagramToB.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException('未发送到最近 UDP 来源'),
        )).data,
        orderedEquals(<int>[4, 5]),
      );

      await transport.close();
      expect(transport.status, TransportStatus.disconnected);
      final rebound = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        boundPort,
      );
      rebound.close();
    } finally {
      await transport.dispose();
      receiverA.close();
      receiverB.close();
    }
  });

  test('UDP 关闭来源跟随时继续使用显式配置的远端', () async {
    final receiverA = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final receiverB = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final transport = UdpTransport(
      bindAddress: InternetAddress.loopbackIPv4.address,
      localPort: 0,
      remoteHost: InternetAddress.loopbackIPv4.address,
      remotePort: receiverA.port,
      followRemoteEndpoint: false,
    );

    try {
      await transport.open();
      final incoming = transport.events.firstWhere(
        (event) =>
            event is TransportDataEvent &&
            event.bytes.length == 1 &&
            event.bytes.single == 8,
      );
      receiverB.send(
        <int>[8],
        InternetAddress.loopbackIPv4,
        transport.boundPort!,
      );
      await incoming.timeout(const Duration(seconds: 2));
      expect(transport.currentRemotePort, receiverA.port);

      final datagramToA = _nextDatagram(receiverA);
      await transport.send(Uint8List.fromList(<int>[6]));
      expect(
        (await datagramToA.timeout(const Duration(seconds: 2))).data,
        orderedEquals(<int>[6]),
      );
    } finally {
      await transport.dispose();
      receiverA.close();
      receiverB.close();
    }
  });
}

Future<Datagram> _nextDatagram(RawDatagramSocket socket) {
  final completer = Completer<Datagram>();
  late final StreamSubscription<RawSocketEvent> subscription;
  subscription = socket.listen(
    (event) {
      if (event != RawSocketEvent.read || completer.isCompleted) {
        return;
      }
      final datagram = socket.receive();
      if (datagram != null) {
        completer.complete(datagram);
        unawaited(subscription.cancel());
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    },
  );
  return completer.future;
}
