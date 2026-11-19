import 'dart:typed_data';

import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_serial_transport.dart';
import '../support/fake_transport.dart';

void main() {
  test('终端控制器切换网络模式、打开监听并释放活动网络传输', () async {
    final serial = FakeSerialTransport(
      initialPorts: const <SerialPortInfo>[
        SerialPortInfo(
          systemPath: 'COM1',
          displayName: 'COM1',
          isAvailable: true,
        ),
      ],
    );
    final factory = RecordingTransportFactory();
    final controller = TerminalController(
      transport: serial,
      textEncoder: const Utf8TextByteEncoder(),
      backendLabel: '测试串口',
      networkTransportFactory: factory,
      initialConfig: const SerialConfig(portName: 'COM1', baudRate: 115200),
    );

    try {
      await controller.initialize();
      await controller.open();
      expect(controller.state.value.status, TransportStatus.connected);

      await controller.switchTransportMode(TransportMode.tcpServer);
      expect(controller.state.value.transportMode, TransportMode.tcpServer);
      expect(controller.state.value.status, TransportStatus.disconnected);
      expect(controller.state.value.backendLabel, 'TCP 服务端');
      expect(serial.status, TransportStatus.disconnected);
      expect(serial.isDisposed, isFalse);

      controller.updateNetworkSettings(
        bindAddress: '127.0.0.1',
        localPort: 6001,
      );
      await controller.open();

      expect(factory.configs, hasLength(1));
      final serverConfig = factory.configs.single;
      expect(serverConfig, isA<TcpServerTransportConfig>());
      expect((serverConfig as TcpServerTransportConfig).port, 6001);
      expect(controller.state.value.status, TransportStatus.listening);
      expect(controller.state.value.connectionDetail, '测试监听中');

      await controller.switchTransportMode(TransportMode.udp);
      expect(controller.state.value.status, TransportStatus.disconnected);
      expect(controller.state.value.transportMode, TransportMode.udp);
      expect(factory.transports.single.wasClosed, isTrue);
      expect(factory.transports.single.isDisposed, isTrue);

      controller.updateNetworkSettings(
        remoteHost: '127.0.0.1',
        remotePort: 6002,
        localPort: 6003,
      );
      await controller.open();
      final udpConfig = factory.configs.last;
      expect(udpConfig, isA<UdpTransportConfig>());
      expect((udpConfig as UdpTransportConfig).remotePort, 6002);
      expect(udpConfig.localPort, 6003);
      expect(controller.state.value.status, TransportStatus.connected);

      final result = await controller.sendBytes(
        Uint8List.fromList(<int>[1, 2]),
      );
      expect(result?.acceptedLength, 2);
      expect(
        factory.transports.last.sentBatches.single,
        orderedEquals(<int>[1, 2]),
      );

      factory.transports.last.simulateDisconnect();
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.value.status, TransportStatus.disconnected);
      expect(controller.state.value.errorMessage, '测试远端断开');
      expect(factory.transports.last.isDisposed, isTrue);
    } finally {
      await controller.dispose();
    }

    expect(serial.isDisposed, isTrue);
  });

  test('网络远端断开后立即切回串口不会丢失新事件订阅', () async {
    final serial = FakeSerialTransport(
      initialPorts: const <SerialPortInfo>[
        SerialPortInfo(
          systemPath: 'COM1',
          displayName: 'COM1',
          isAvailable: true,
        ),
      ],
    );
    final factory = RecordingTransportFactory();
    final controller = TerminalController(
      transport: serial,
      textEncoder: const Utf8TextByteEncoder(),
      backendLabel: '测试串口',
      networkTransportFactory: factory,
      initialConfig: const SerialConfig(portName: 'COM1', baudRate: 115200),
    );

    try {
      await controller.initialize();
      await controller.switchTransportMode(TransportMode.udp);
      controller.updateNetworkSettings(
        remoteHost: '127.0.0.1',
        remotePort: 6002,
        localPort: 6003,
      );
      await controller.open();
      factory.transports.single.simulateDisconnect();

      await controller.switchTransportMode(TransportMode.serial);
      expect(controller.state.value.transportMode, TransportMode.serial);
      expect(factory.transports.single.isDisposed, isTrue);

      await controller.open();
      serial.injectData(Uint8List.fromList(<int>[1, 2, 3]));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.state.value.receivedBytes, 3);
    } finally {
      await controller.dispose();
    }
  });

  test('Safe 模式拒绝非回环监听且不会创建网络传输', () async {
    final factory = RecordingTransportFactory();
    final controller = TerminalController(
      transport: FakeSerialTransport(),
      textEncoder: const Utf8TextByteEncoder(),
      backendLabel: '测试串口',
      networkTransportFactory: factory,
      initialTransportMode: TransportMode.tcpServer,
      initialNetworkSafetyMode: NetworkSafetyMode.safe,
      initialBindAddress: '0.0.0.0',
      initialLocalPort: 6001,
    );

    try {
      await controller.initialize();
      await controller.open();

      expect(controller.state.value.errorMessage, contains('Safe 模式禁止'));
      expect(factory.configs, isEmpty);
      expect(controller.state.value.status, TransportStatus.disconnected);
    } finally {
      await controller.dispose();
    }
  });
}
