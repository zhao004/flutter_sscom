import 'dart:typed_data';

import 'package:flutter_sscom/core/isp/isp_protocol.dart';
import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/isp/infrastructure/terminal_isp_link.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_serial_transport.dart';

void main() {
  test('TerminalIspLink 聚合串口分包并保持读取顺序', () async {
    final transport = FakeSerialTransport(
      initialPorts: const <SerialPortInfo>[
        SerialPortInfo(
          systemPath: 'COM1',
          displayName: 'COM1',
          isAvailable: true,
        ),
      ],
    );
    final terminal = TerminalController(
      transport: transport,
      textEncoder: const Utf8TextByteEncoder(),
      backendLabel: '测试串口',
      initialConfig: const SerialConfig(portName: 'COM1', baudRate: 115200),
    );
    final owner = Object();
    TerminalIspLink? link;

    try {
      await terminal.initialize();
      await terminal.open();
      expect(terminal.acquireExclusiveSend(owner), isTrue);
      link = TerminalIspLink(terminal: terminal, owner: owner);
      final response = link.readExact(3, timeout: const Duration(seconds: 1));
      transport.injectData(Uint8List.fromList(<int>[1]));
      transport.injectData(Uint8List.fromList(<int>[2, 3, 4]));
      expect(await response, orderedEquals(<int>[1, 2, 3]));
      expect(
        await link.readExact(1, timeout: const Duration(seconds: 1)),
        orderedEquals(<int>[4]),
      );
    } finally {
      await link?.close();
      terminal.releaseExclusiveSend(owner);
      await terminal.dispose();
    }
  });

  test('TerminalIspLink 超时返回稳定 ISP 错误', () async {
    final transport = FakeSerialTransport(
      initialPorts: const <SerialPortInfo>[
        SerialPortInfo(
          systemPath: 'COM1',
          displayName: 'COM1',
          isAvailable: true,
        ),
      ],
    );
    final terminal = TerminalController(
      transport: transport,
      textEncoder: const Utf8TextByteEncoder(),
      backendLabel: '测试串口',
      initialConfig: const SerialConfig(portName: 'COM1', baudRate: 115200),
    );
    final owner = Object();
    TerminalIspLink? link;

    try {
      await terminal.initialize();
      await terminal.open();
      expect(terminal.acquireExclusiveSend(owner), isTrue);
      link = TerminalIspLink(terminal: terminal, owner: owner);
      await expectLater(
        link.readExact(1, timeout: const Duration(milliseconds: 1)),
        throwsA(
          isA<IspException>().having(
            (error) => error.code,
            'code',
            IspErrorCode.timeout,
          ),
        ),
      );
    } finally {
      await link?.close();
      terminal.releaseExclusiveSend(owner);
      await terminal.dispose();
    }
  });
}
