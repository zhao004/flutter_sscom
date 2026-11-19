import 'dart:typed_data';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_serial_transport.dart';

void main() {
  group('FakeSerialTransport', () {
    test('打开、设置信号、发送和幂等关闭形成完整状态转换', () async {
      final transport = FakeSerialTransport(
        initialConfig: const SerialConfig(
          portName: 'COM7',
          baudRate: 921600,
          initialDtr: true,
        ),
      );
      final events = <TransportEvent>[];
      final subscription = transport.events.listen(events.add);

      expect(transport.status, TransportStatus.disconnected);
      await transport.open();
      expect(transport.status, TransportStatus.connected);
      expect(transport.signals.dtr, isTrue);
      expect(transport.signals.rts, isFalse);

      await transport.setRts(true);
      await transport.setDtr(false);
      expect(transport.signals.dtr, isFalse);
      expect(transport.signals.rts, isTrue);

      final result = await transport.send(
        Uint8List.fromList(<int>[0x01, 0x02, 0x03]),
      );
      expect(result.requestedLength, 3);
      expect(result.acceptedLength, 3);
      expect(result.isComplete, isTrue);
      expect(transport.sentBatches, hasLength(1));
      expect(
        transport.sentBatches.single,
        orderedEquals(<int>[0x01, 0x02, 0x03]),
      );

      final exposedBatch = transport.sentBatches.single;
      exposedBatch[0] = 0xFF;
      expect(transport.sentBatches.single[0], 0x01);

      await transport.close();
      await transport.close();
      expect(transport.status, TransportStatus.disconnected);
      expect(events.whereType<TransportConnectedEvent>(), hasLength(1));
      expect(events.whereType<TransportSignalChangedEvent>(), hasLength(3));
      expect(events.whereType<TransportDisconnectedEvent>(), hasLength(1));

      await subscription.cancel();
      await transport.dispose();
    });

    test('端口枚举返回快照并广播热插拔列表', () async {
      const initialPort = SerialPortInfo(
        systemPath: 'COM1',
        displayName: 'COM1',
        isAvailable: true,
      );
      const addedPort = SerialPortInfo(
        systemPath: 'COM2',
        displayName: 'USB-SERIAL CH340 (COM2)',
        isAvailable: true,
      );
      final transport = FakeSerialTransport(
        initialPorts: const <SerialPortInfo>[initialPort],
      );
      final changes = <List<SerialPortInfo>>[];
      final subscription = transport.portChanges.listen(changes.add);

      final initialSnapshot = await transport.listPorts();
      expect(initialSnapshot.single.systemPath, 'COM1');

      transport.setPorts(const <SerialPortInfo>[initialPort, addedPort]);
      expect(changes, hasLength(1));
      expect(changes.single.map((port) => port.systemPath), <String>[
        'COM1',
        'COM2',
      ]);
      expect(
        (await transport.listPorts()).map((port) => port.systemPath),
        <String>['COM1', 'COM2'],
      );

      await subscription.cancel();
      await transport.dispose();
    });

    test('打开失败暴露错误事件并进入错误状态', () async {
      const failure = TransportError(
        code: TransportErrorCode.portBusy,
        message: '端口被占用',
      );
      final transport = FakeSerialTransport(openError: failure);
      final events = <TransportEvent>[];
      final subscription = transport.events.listen(events.add);

      await expectLater(
        transport.open(),
        throwsA(
          isA<TransportException>().having(
            (error) => error.error.code,
            'code',
            TransportErrorCode.portBusy,
          ),
        ),
      );
      expect(transport.status, TransportStatus.error);
      expect(
        events.whereType<TransportErrorEvent>().single.error,
        same(failure),
      );

      await transport.close();
      expect(transport.status, TransportStatus.disconnected);
      await subscription.cancel();
      await transport.dispose();
    });

    test('发送失败和未连接发送使用稳定错误分类', () async {
      const failure = TransportError(
        code: TransportErrorCode.writeFailed,
        message: '写入失败',
      );
      final transport = FakeSerialTransport(sendError: failure);
      final events = <TransportEvent>[];
      final subscription = transport.events.listen(events.add);

      await expectLater(
        transport.send(Uint8List.fromList(<int>[1])),
        throwsA(
          isA<TransportException>().having(
            (error) => error.error.code,
            'code',
            TransportErrorCode.disconnected,
          ),
        ),
      );

      await transport.open();
      await expectLater(
        transport.send(Uint8List.fromList(<int>[1])),
        throwsA(
          isA<TransportException>().having(
            (error) => error.error.code,
            'code',
            TransportErrorCode.writeFailed,
          ),
        ),
      );
      expect(transport.sentBatches, isEmpty);
      expect(
        events.whereType<TransportErrorEvent>().single.error,
        same(failure),
      );

      await subscription.cancel();
      await transport.dispose();
    });

    test('配置仅允许在断开状态执行', () async {
      final transport = FakeSerialTransport();
      const configured = SerialConfig(
        portName: 'COM5',
        baudRate: 57600,
        dataBits: SerialDataBits.seven,
        stopBits: SerialStopBits.two,
        parity: SerialParity.even,
        flowControl: SerialFlowControl.rtsCts,
      );

      await transport.configure(configured);
      expect(transport.config.portName, 'COM5');
      expect(transport.config.baudRate, 57600);

      await transport.open();
      await expectLater(
        transport.configure(configured),
        throwsA(
          isA<TransportException>().having(
            (error) => error.error.code,
            'code',
            TransportErrorCode.configureWhileOpen,
          ),
        ),
      );

      await transport.close();
      await expectLater(
        transport.setDtr(true),
        throwsA(
          isA<TransportException>().having(
            (error) => error.error.code,
            'code',
            TransportErrorCode.disconnected,
          ),
        ),
      );
      await transport.dispose();
    });

    test('可注入接收数据、错误和信号状态并复制输入字节', () async {
      final transport = FakeSerialTransport();
      await transport.open();
      final events = <TransportEvent>[];
      final subscription = transport.events.listen(events.add);

      final input = Uint8List.fromList(<int>[0x10, 0x20]);
      transport.injectData(input);
      input[0] = 0xFF;
      expect(
        events.whereType<TransportDataEvent>().single.bytes,
        orderedEquals(<int>[0x10, 0x20]),
      );

      const injectedError = TransportError(
        code: TransportErrorCode.readFailed,
        message: '读取失败',
      );
      transport.injectError(injectedError);
      expect(
        events.whereType<TransportErrorEvent>().single.error,
        same(injectedError),
      );

      const signals = SerialSignalState(
        cts: true,
        dsr: true,
        dcd: false,
        ri: true,
        dtr: true,
        rts: false,
      );
      await transport.injectSignals(signals);
      expect(transport.signals.cts, isTrue);
      expect(transport.signals.ri, isTrue);
      expect(transport.signals.dtr, isTrue);

      transport.simulateDisconnect(reason: 'USB 设备移除');
      expect(transport.status, TransportStatus.disconnected);
      expect(
        events.whereType<TransportDisconnectedEvent>().single.reason,
        'USB 设备移除',
      );
      expect(
        () => transport.injectData(Uint8List.fromList(<int>[1])),
        throwsA(
          isA<TransportException>().having(
            (error) => error.error.code,
            'code',
            TransportErrorCode.disconnected,
          ),
        ),
      );

      await subscription.cancel();
      await transport.dispose();
    });
  });
}
