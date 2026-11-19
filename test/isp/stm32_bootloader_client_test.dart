import 'dart:typed_data';

import 'package:flutter_sscom/core/isp/firmware_image.dart';
import 'package:flutter_sscom/core/isp/isp_protocol.dart';
import 'package:flutter_sscom/core/isp/stm32_bootloader_client.dart';
import 'package:flutter_sscom/core/isp/stm32_bootloader_simulator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('STM32 bootloader 完成识别、擦除、分块写入、校验和启动', () async {
    final simulator = Stm32BootloaderSimulator();
    final client = Stm32BootloaderClient(
      link: simulator,
      options: Stm32IspOptions(blockSize: 3),
    );
    final image = FirmwareImage(
      segments: <FirmwareSegment>[
        FirmwareSegment(
          startAddress: 0x08000000,
          bytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
        ),
        FirmwareSegment(
          startAddress: 0x08000010,
          bytes: Uint8List.fromList(<int>[9]),
        ),
      ],
      entryPoint: 0x08000000,
    );
    final progress = <IspProgress>[];

    try {
      final info = await client.connect();
      expect(info.productIdValue, 0x0410);
      expect(info.bootloaderVersion, 0x31);
      expect(info.supports(Stm32BootloaderClient.commandExtendedErase), isTrue);

      await client.eraseAll();
      await client.writeImage(image, onProgress: progress.add);
      await client.verifyImage(image, onProgress: progress.add);
      await client.go(image.entryPoint!);

      final flash = simulator.readFlash();
      expect(flash.sublist(0, 5), orderedEquals(<int>[1, 2, 3, 4, 5]));
      expect(flash[0x10], 9);
      expect(simulator.startedAddress, 0x08000000);
      expect(
        progress
            .where((event) => event.phase == IspOperationPhase.writing)
            .last
            .completedBytes,
        6,
      );
      expect(
        progress
            .where((event) => event.phase == IspOperationPhase.verifying)
            .last
            .completedBytes,
        6,
      );
    } finally {
      await simulator.close();
    }
  });

  test('固件超出配置 Flash 范围时拒绝擦写', () async {
    final simulator = Stm32BootloaderSimulator(flashSizeBytes: 16);
    final client = Stm32BootloaderClient(
      link: simulator,
      options: Stm32IspOptions(flashSizeBytes: 16),
    );
    final image = FirmwareImage(
      segments: <FirmwareSegment>[
        FirmwareSegment(
          startAddress: 0x0800000F,
          bytes: Uint8List.fromList(<int>[1, 2]),
        ),
      ],
    );

    try {
      expect(
        () => client.validateImage(image),
        throwsA(
          isA<IspException>().having(
            (error) => error.code,
            'code',
            IspErrorCode.addressOutOfRange,
          ),
        ),
      );
    } finally {
      await simulator.close();
    }
  });

  test('同步超时包含有界尝试次数与明确错误', () async {
    final link = _TimeoutIspLink();
    final client = Stm32BootloaderClient(
      link: link,
      options: Stm32IspOptions(
        syncAttempts: 3,
        syncTimeout: const Duration(milliseconds: 1),
      ),
    );

    await expectLater(
      client.connect(),
      throwsA(
        isA<IspException>().having(
          (error) => error.code,
          'code',
          IspErrorCode.timeout,
        ),
      ),
    );
    expect(link.writeCount, 3);
  });

  test('写入前检查取消令牌', () async {
    final simulator = Stm32BootloaderSimulator();
    final client = Stm32BootloaderClient(
      link: simulator,
      options: Stm32IspOptions(),
    );
    final cancellation = IspCancellationToken()..cancel();
    final image = FirmwareImage(
      segments: <FirmwareSegment>[
        FirmwareSegment(
          startAddress: 0x08000000,
          bytes: Uint8List.fromList(<int>[1]),
        ),
      ],
    );

    try {
      await client.connect();
      await expectLater(
        client.writeImage(image, cancellation: cancellation),
        throwsA(isA<IspCancelledException>()),
      );
    } finally {
      await simulator.close();
    }
  });
}

final class _TimeoutIspLink implements IspLink {
  int writeCount = 0;

  @override
  Future<void> write(Uint8List bytes) async {
    writeCount++;
  }

  @override
  Future<Uint8List> readExact(int length, {required Duration timeout}) async {
    throw const IspException(code: IspErrorCode.timeout, message: '模拟无响应');
  }

  @override
  Future<void> clearInput() async {}

  @override
  Future<void> setDtr(bool enabled) async {}

  @override
  Future<void> setRts(bool enabled) async {}

  @override
  Future<void> close() async {}
}
