import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/connection/infrastructure/simulated_serial_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SimulatedSerialTransport', () {
    test('枚举固定模拟端口并广播快照', () {
      fakeAsync((async) {
        final transport = SimulatedSerialTransport();
        final changes = <List<SerialPortInfo>>[];
        final subscription = transport.portChanges.listen(changes.add);
        List<SerialPortInfo>? ports;

        unawaited(transport.listPorts().then((value) => ports = value));
        async.flushMicrotasks();

        expect(ports, hasLength(2));
        expect(ports!.map((port) => port.systemPath), <String>[
          'SIM-A',
          'SIM-B',
        ]);
        expect(changes, hasLength(1));

        unawaited(subscription.cancel());
        unawaited(transport.dispose());
        async.flushMicrotasks();
      });
    });

    test('打开后按配置初始化信号，发送数据定时原样回显', () {
      fakeAsync((async) {
        final transport = SimulatedSerialTransport(
          initialConfig: const SerialConfig(
            portName: 'SIM-B',
            baudRate: 921600,
            initialDtr: true,
            initialRts: true,
          ),
          echoDelay: const Duration(milliseconds: 25),
        );
        final events = <TransportEvent>[];
        final subscription = transport.events.listen(events.add);

        unawaited(transport.open());
        async.flushMicrotasks();
        expect(transport.status, TransportStatus.connected);
        expect(
          events.whereType<TransportSignalChangedEvent>().single.signals.dtr,
          isTrue,
        );

        unawaited(transport.send(Uint8List.fromList(<int>[0x41, 0x42])));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 24));
        expect(events.whereType<TransportDataEvent>(), isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(
          events.whereType<TransportDataEvent>().single.bytes,
          orderedEquals(<int>[0x41, 0x42]),
        );

        unawaited(transport.setDtr(false));
        unawaited(transport.setRts(false));
        async.flushMicrotasks();
        expect(transport.status, TransportStatus.connected);

        unawaited(transport.close());
        async.flushMicrotasks();
        expect(transport.status, TransportStatus.disconnected);

        unawaited(subscription.cancel());
        unawaited(transport.dispose());
        async.flushMicrotasks();
      });
    });

    test('关闭取消尚未回显的发送数据', () {
      fakeAsync((async) {
        final transport = SimulatedSerialTransport(
          echoDelay: const Duration(seconds: 1),
        );
        final events = <TransportEvent>[];
        final subscription = transport.events.listen(events.add);

        unawaited(transport.open());
        unawaited(transport.send(Uint8List.fromList(<int>[1])));
        async.flushMicrotasks();
        unawaited(transport.close());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));

        expect(events.whereType<TransportDataEvent>(), isEmpty);
        unawaited(subscription.cancel());
        unawaited(transport.dispose());
        async.flushMicrotasks();
      });
    });

    test('未连接发送和配置变更返回结构化错误', () {
      fakeAsync((async) {
        final transport = SimulatedSerialTransport();
        Object? sendError;
        Object? configureError;

        unawaited(() async {
          try {
            await transport.send(Uint8List.fromList(<int>[1]));
          } catch (error) {
            sendError = error;
          }
        }());
        unawaited(transport.open());
        async.flushMicrotasks();
        unawaited(() async {
          try {
            await transport.configure(
              const SerialConfig(portName: 'SIM-A', baudRate: 9600),
            );
          } catch (error) {
            configureError = error;
          }
        }());
        async.flushMicrotasks();

        expect(sendError, isA<TransportException>());
        expect(
          (sendError! as TransportException).error.code,
          TransportErrorCode.disconnected,
        );
        expect(configureError, isA<TransportException>());
        expect(
          (configureError! as TransportException).error.code,
          TransportErrorCode.configureWhileOpen,
        );

        unawaited(transport.dispose());
        async.flushMicrotasks();
      });
    });
  });
}
