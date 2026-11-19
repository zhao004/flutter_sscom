import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/connection/infrastructure/tcp_client_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TCP 对端不读取时关闭能中止受阻发送且不留下异步异常', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<Socket>();
    final subscription = server.listen(accepted.complete);
    final transport = TcpClientTransport(host: '127.0.0.1', port: server.port);
    Socket? peer;
    try {
      await transport.open();
      peer = await accepted.future;
      var completed = false;
      final send = transport.send(Uint8List(32 * 1024 * 1024));
      final checked = expectLater(send, throwsA(isA<TransportException>()));
      unawaited(
        send.then<void>(
          (_) {
            completed = true;
          },
          onError: (Object _) {
            completed = true;
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(completed, isFalse);
      await transport.dispose().timeout(const Duration(seconds: 2));
      await checked.timeout(const Duration(seconds: 2));
    } finally {
      peer?.destroy();
      await transport.dispose();
      await subscription.cancel();
      await server.close();
    }
  });

  test('TCP 客户端完成回环连接、双向收发和有序关闭', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<Socket>();
    final serverData = Completer<Uint8List>();
    final acceptSubscription = server.listen((socket) {
      if (!accepted.isCompleted) {
        accepted.complete(socket);
      }
      socket.listen((bytes) {
        if (!serverData.isCompleted) {
          serverData.complete(Uint8List.fromList(bytes));
        }
      });
    });
    final transport = TcpClientTransport(
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      connectTimeout: const Duration(seconds: 2),
    );

    try {
      final connected = transport.events.firstWhere(
        (event) => event is TransportConnectedEvent,
      );
      await transport.open();
      await connected.timeout(const Duration(seconds: 2));
      final socket = await accepted.future.timeout(const Duration(seconds: 2));
      expect(transport.status, TransportStatus.connected);

      final clientResult = await transport.send(
        Uint8List.fromList(<int>[1, 2]),
      );
      expect(clientResult.acceptedLength, 2);
      expect(
        await serverData.future.timeout(const Duration(seconds: 2)),
        orderedEquals(<int>[1, 2]),
      );

      final received = transport.events.firstWhere(
        (event) =>
            event is TransportDataEvent &&
            event.bytes.length == 2 &&
            event.bytes[0] == 3,
      );
      socket.add(<int>[3, 4]);
      await socket.flush();
      final dataEvent = await received.timeout(
        const Duration(seconds: 2),
      ) as TransportDataEvent;
      expect(dataEvent.bytes, orderedEquals(<int>[3, 4]));

      await transport.close();
      expect(transport.status, TransportStatus.disconnected);
    } finally {
      await transport.dispose();
      await acceptSubscription.cancel();
      await server.close();
    }
  });

  test('TCP 客户端连接拒绝映射为错误状态且可重试', () async {
    final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserved.port;
    await reserved.close();
    final transport = TcpClientTransport(
      host: InternetAddress.loopbackIPv4.address,
      port: port,
      connectTimeout: const Duration(seconds: 1),
    );

    try {
      await expectLater(transport.open(), throwsA(isA<TransportException>()));
      expect(transport.status, TransportStatus.error);
    } finally {
      await transport.dispose();
    }
  });
}
