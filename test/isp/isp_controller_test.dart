import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/isp/application/isp_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_serial_transport.dart';

void main() {
  test('STM32 模拟器完成识别、烧录、校验和启动', () async {
    final controller = IspController(
      terminal: TerminalController(
        transport: FakeSerialTransport(),
        textEncoder: const Utf8TextByteEncoder(),
        backendLabel: '测试串口',
      ),
    );

    try {
      await controller.setConnectionSource(IspConnectionSource.stm32Simulator);
      controller.setRunAfterProgramming(true);
      await controller.loadFirmware(
        File('test/fixtures/firmware/stm32_sample.hex'),
      );
      expect(controller.state.value.firmwareError, isNull);
      expect(controller.state.value.image?.totalBytes, 8);

      await controller.inspectDevice();
      expect(controller.state.value.phase, IspPhase.ready);
      expect(controller.state.value.deviceInfo?.productIdValue, 0x0410);

      await controller.program();
      expect(controller.state.value.phase, IspPhase.completed);
      expect(controller.state.value.errorMessage, isNull);
    } finally {
      await controller.dispose();
    }
  });

  test('识别后修改 Flash 容量会释放旧会话并要求重新识别', () async {
    final controller = IspController(
      terminal: TerminalController(
        transport: FakeSerialTransport(),
        textEncoder: const Utf8TextByteEncoder(),
        backendLabel: '测试串口',
      ),
    );

    try {
      await controller.setConnectionSource(IspConnectionSource.stm32Simulator);
      await controller.loadFirmware(
        File('test/fixtures/firmware/stm32_sample.hex'),
      );
      await controller.inspectDevice();
      expect(controller.state.value.phase, IspPhase.ready);
      expect(controller.state.value.deviceInfo, isNotNull);

      await controller.setFlashSizeKiB(128);

      expect(controller.state.value.flashSizeKiB, 128);
      expect(controller.state.value.phase, IspPhase.idle);
      expect(controller.state.value.deviceInfo, isNull);
      expect(controller.state.value.message, contains('重新识别'));

      await controller.inspectDevice();
      expect(controller.state.value.phase, IspPhase.ready);
      await controller.endSession();
      expect(controller.state.value.phase, IspPhase.idle);
      expect(controller.state.value.deviceInfo, isNull);
      expect(controller.state.value.message, contains('控制权已释放'));
    } finally {
      await controller.dispose();
    }
  });

  test('STC/IAP15 入口明确拒绝未经验证的烧录', () async {
    final controller = IspController(
      terminal: TerminalController(
        transport: FakeSerialTransport(),
        textEncoder: const Utf8TextByteEncoder(),
        backendLabel: '测试串口',
      ),
    );

    try {
      await controller.setFamily(IspTargetFamily.stc15);
      await controller.inspectDevice();
      expect(controller.state.value.phase, IspPhase.failed);
      expect(controller.state.value.errorMessage, contains('硬件 trace'));
    } finally {
      await controller.dispose();
    }
  });

  test('串口独占发送阻止普通发送并允许 owner 发送', () async {
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

    try {
      await terminal.initialize();
      await terminal.open();
      expect(terminal.acquireExclusiveSend(owner), isTrue);
      expect(await terminal.sendBytes(Uint8List.fromList(<int>[1])), isNull);
      final result = await terminal.sendBytes(
        Uint8List.fromList(<int>[2]),
        exclusiveOwner: owner,
      );
      expect(result?.acceptedLength, 1);
      expect(transport.sentBatches.single, orderedEquals(<int>[2]));

      terminal.releaseExclusiveSend(owner);
      expect(terminal.state.value.isExclusiveSend, isFalse);
    } finally {
      await terminal.dispose();
    }
  });
}
