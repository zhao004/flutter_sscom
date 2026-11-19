import 'dart:typed_data';

import 'package:flutter_sscom/core/isp/firmware_image.dart';
import 'package:flutter_sscom/core/isp/isp_protocol.dart';
import 'package:flutter_sscom/core/isp/stm32_bootloader_client.dart';
import 'package:flutter_sscom/core/isp/stm32_bootloader_simulator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('对齐填充后的边界在任何擦写命令前被拒绝', () async {
    for (final start in [0x08000001, 0x08000000]) {
      final link = _TimeoutIspLink();
      final client = Stm32BootloaderClient(
        link: link,
        options: Stm32IspOptions(flashStartAddress: start, flashSizeBytes: 3),
      );
      final image = FirmwareImage(
        segments: [
          FirmwareSegment(
            startAddress: start,
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ],
      );
      expect(
        () => client.prepareImage(image),
        throwsA(
          isA<IspException>().having(
            (error) => error.code,
            'code',
            IspErrorCode.addressOutOfRange,
          ),
        ),
      );
      expect(link.writeCount, 0);
    }
  });

  test('低层 Write Memory 和块参数在发送前拒绝非法对齐', () async {
    final link = _TimeoutIspLink();
    final client = Stm32BootloaderClient(
      link: link,
      options: Stm32IspOptions(),
    );
    for (final size in [1, 3, 255]) {
      expect(() => Stm32IspOptions(blockSize: size), throwsArgumentError);
    }
    await expectLater(
      client.writeMemory(0x08000001, Uint8List(4)),
      throwsArgumentError,
    );
    await expectLater(
      client.writeMemory(0x08000000, Uint8List(1)),
      throwsArgumentError,
    );
    expect(link.writeCount, 0);
  });

  test('Go 使用应用向量表基址并支持偏移后的应用', () async {
    final simulator = Stm32BootloaderSimulator();
    final client = Stm32BootloaderClient(
      link: simulator,
      options: Stm32IspOptions(),
    );
    final vectors = Uint8List(12);
    ByteData.sublistView(vectors)
      ..setUint32(0, 0x20001000, Endian.little)
      ..setUint32(4, 0x08001009, Endian.little);
    final image = FirmwareImage(
      segments: [FirmwareSegment(startAddress: 0x08001000, bytes: vectors)],
      entryPoint: 0x08001009,
    );
    try {
      await client.connect();
      final address = client.applicationVectorAddress(image);
      expect(address, 0x08001000);
      await client.go(address);
      expect(simulator.startedAddress, 0x08001000);
      for (final reset in [0, 0xFFFFFFFF, 0x08001008, 0x08002001]) {
        ByteData.sublistView(vectors).setUint32(4, reset, Endian.little);
        expect(
          () => client.applicationVectorAddress(
            FirmwareImage(
              segments: [
                FirmwareSegment(startAddress: 0x08001000, bytes: vectors),
              ],
            ),
          ),
          throwsA(isA<IspException>()),
        );
      }
    } finally {
      await simulator.close();
    }
  });

  test('257 字节和未对齐的稀疏段合并填充后按字写入', () async {
    final simulator = Stm32BootloaderSimulator();
    final client = Stm32BootloaderClient(
      link: simulator,
      options: Stm32IspOptions(),
    );
    final image = FirmwareImage(
      segments: [
        FirmwareSegment(
          startAddress: 0x08000001,
          bytes: Uint8List.fromList(List<int>.filled(257, 0x55)),
        ),
        FirmwareSegment(
          startAddress: 0x08000103,
          bytes: Uint8List.fromList([0xAA]),
        ),
      ],
    );
    try {
      await client.connect();
      await client.writeImage(image);
      await client.verifyImage(image);
      final flash = simulator.readFlash();
      expect(flash[0], 0xFF);
      expect(flash.sublist(1, 258), everyElement(0x55));
      expect(flash[258], 0xFF);
      expect(flash[259], 0xAA);
    } finally {
      await simulator.close();
    }
  });

  test('模拟器拒绝未对齐地址及非整字长度且不改变 Flash', () async {
    for (final address in [0x08000000, 0x08000001]) {
      final simulator = Stm32BootloaderSimulator();
      try {
        await simulator.write(Uint8List.fromList([0x31, 0xCE]));
        expect(
          await simulator.readExact(1, timeout: const Duration(seconds: 1)),
          [0x79],
        );
        final bytes = [
          (address >> 24) & 255,
          (address >> 16) & 255,
          (address >> 8) & 255,
          address & 255,
        ];
        await simulator.write(
          Uint8List.fromList([...bytes, bytes.reduce((a, b) => a ^ b)]),
        );
        final response = await simulator.readExact(
          1,
          timeout: const Duration(seconds: 1),
        );
        if (address.isEven) {
          expect(response, [0x79]);
          await simulator.write(Uint8List.fromList([0, 0xAA, 0xAA]));
          expect(
            await simulator.readExact(1, timeout: const Duration(seconds: 1)),
            [0x1F],
          );
        } else {
          expect(response, [0x1F]);
        }
        expect(simulator.readFlash(), everyElement(0xFF));
      } finally {
        await simulator.close();
      }
    }
  });

  test('STM32 bootloader 完成识别、擦除、分块写入、校验和启动', () async {
    final simulator = Stm32BootloaderSimulator();
    final client = Stm32BootloaderClient(
      link: simulator,
      options: Stm32IspOptions(blockSize: 4),
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
        12,
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
