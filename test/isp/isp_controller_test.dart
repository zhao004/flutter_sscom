import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/isp/isp_protocol.dart';
import 'package:flutter_sscom/core/isp/stm32_bootloader_simulator.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/isp/application/isp_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_serial_transport.dart';

void main() {
  for (final validVector in [true, false]) {
    test(validVector ? '控制器向 Go 发送向量表基址而非 HEX 入口' : '无效启动向量在全片擦除前拒绝', () async {
      final simulator = Stm32BootloaderSimulator();
      final serial = FakeSerialTransport(
        initialPorts: const [
          SerialPortInfo(
            systemPath: 'COM1',
            displayName: 'COM1',
            isAvailable: true,
          ),
        ],
      );
      serial.sendHandler = (bytes) async {
        await simulator.write(bytes);
        final response = <int>[];
        while (true) {
          try {
            response.addAll(
              await simulator.readExact(1, timeout: const Duration(seconds: 1)),
            );
          } on IspException catch (error) {
            if (error.code != IspErrorCode.timeout) {
              rethrow;
            }
            break;
          }
        }
        if (response.isNotEmpty) {
          serial.injectData(Uint8List.fromList(response));
        }
      };
      final vectors = Uint8List(12);
      ByteData.sublistView(vectors)
        ..setUint32(0, 0x20001000, Endian.little)
        ..setUint32(4, validVector ? 0x08001009 : 0x08001008, Endian.little);
      final firmware = [
        _record(0, 4, [8, 0]),
        _record(0x1000, 0, vectors),
        _record(0, 5, [8, 0, 0x10, 9]),
        _record(0, 1, []),
      ].join('\n');
      final terminal = TerminalController(
        transport: serial,
        textEncoder: const Utf8TextByteEncoder(),
        backendLabel: '模拟设备',
        initialConfig: const SerialConfig(
          portName: 'COM1',
          baudRate: 115200,
          parity: SerialParity.even,
        ),
      );
      final controller = IspController(
        terminal: terminal,
        firmwareBytesReader: (_) async =>
            Uint8List.fromList(firmware.codeUnits),
      );
      try {
        await terminal.initialize();
        await terminal.open();
        await controller.loadFirmware(File('application.hex'));
        controller.setRunAfterProgramming(true);
        await controller.inspectDevice();
        expect(controller.state.value.phase, IspPhase.ready);
        await controller.program();
        if (validVector) {
          expect(controller.state.value.phase, IspPhase.completed);
          expect(simulator.startedAddress, 0x08001000);
        } else {
          expect(controller.state.value.phase, IspPhase.failed);
          expect(controller.state.value.errorMessage, contains('向量表无效'));
          expect(
            serial.sentBatches.any(
              (batch) =>
                  batch.length == 2 &&
                  (batch.first == 0x43 || batch.first == 0x44),
            ),
            isFalse,
          );
          expect(simulator.startedAddress, isNull);
        }
      } finally {
        await controller.dispose();
        await terminal.dispose();
        await simulator.close();
      }
    });
  }

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

String _record(int address, int type, List<int> data) {
  final bytes = [data.length, address >> 8, address & 255, type, ...data];
  bytes.add(-bytes.fold<int>(0, (sum, byte) => sum + byte) & 255);
  return ':${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
}
