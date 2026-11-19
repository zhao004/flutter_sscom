import 'dart:typed_data';

import 'firmware_image.dart';
import 'isp_protocol.dart';

/// STM32/GD32 UART bootloader 识别结果。
final class Stm32DeviceInfo {
  /// 创建设备信息。
  Stm32DeviceInfo({
    required this.bootloaderVersion,
    required Set<int> commands,
    required Uint8List productId,
  }) : productId = Uint8List.fromList(productId),
       commands = Set<int>.unmodifiable(commands);

  /// bootloader 版本字节。
  final int bootloaderVersion;

  /// bootloader 支持的完整命令码集合。
  final Set<int> commands;

  /// 产品 ID 原始响应字节，最多 4 字节。
  final Uint8List productId;

  /// 将产品 ID 表示为大端整数。
  int get productIdValue =>
      productId.fold<int>(0, (value, byte) => (value << 8) | byte);

  /// 是否支持指定命令。
  bool supports(int command) => commands.contains(command);
}

/// STM32/GD32 UART bootloader 操作参数。
final class Stm32IspOptions {
  /// 创建操作参数。
  Stm32IspOptions({
    this.flashStartAddress = 0x08000000,
    this.flashSizeBytes = 64 * 1024,
    this.blockSize = 256,
    this.syncAttempts = 10,
    this.syncTimeout = const Duration(milliseconds: 800),
    this.commandTimeout = const Duration(seconds: 3),
    this.eraseTimeout = const Duration(seconds: 45),
  }) {
    if (flashStartAddress < 0 || flashStartAddress > 0xFFFFFFFF) {
      throw ArgumentError.value(flashStartAddress, 'flashStartAddress');
    }
    if (flashSizeBytes <= 0 ||
        flashStartAddress + flashSizeBytes > 0x100000000) {
      throw ArgumentError.value(flashSizeBytes, 'flashSizeBytes');
    }
    if (blockSize < 4 || blockSize > 256 || blockSize % 4 != 0) {
      throw ArgumentError.value(
        blockSize,
        'blockSize',
        '块大小必须为 4 到 256 之间的 4 的倍数',
      );
    }
    if (syncAttempts <= 0) {
      throw ArgumentError.value(syncAttempts, 'syncAttempts');
    }
  }

  /// Flash 起始地址。
  final int flashStartAddress;

  /// 允许写入的 Flash 容量。
  final int flashSizeBytes;

  /// 单次 Write Memory 最大块大小。
  final int blockSize;

  /// 同步 0x7F 的最大尝试次数。
  final int syncAttempts;

  /// 单次同步等待时间。
  final Duration syncTimeout;

  /// 普通命令 ACK 等待时间。
  final Duration commandTimeout;

  /// 全片擦除 ACK 等待时间。
  final Duration eraseTimeout;

  /// Flash 尾后一地址。
  int get flashEndAddressExclusive => flashStartAddress + flashSizeBytes;
}

/// STM32/GD32 UART bootloader 协议客户端。
///
/// 协议依据 ST AN3155/AN4872 的公开命令序列实现。客户端只负责字节协议，
/// 不管理串口生命周期、DTR/RTS 或 UI。所有擦除、写入和回读命令都受地址范围
/// 与取消令牌约束。
final class Stm32BootloaderClient {
  /// 创建客户端。
  Stm32BootloaderClient({required this.link, required this.options});

  /// ACK 字节。
  static const int ack = 0x79;

  /// NACK 字节。
  static const int nack = 0x1F;

  /// 同步字节。
  static const int synchronize = 0x7F;

  /// Get 命令。
  static const int commandGet = 0x00;

  /// Get ID 命令。
  static const int commandGetId = 0x02;

  /// Read Memory 命令。
  static const int commandReadMemory = 0x11;

  /// Go 命令。
  static const int commandGo = 0x21;

  /// Write Memory 命令。
  static const int commandWriteMemory = 0x31;

  /// Erase Memory 命令。
  static const int commandErase = 0x43;

  /// Extended Erase Memory 命令。
  static const int commandExtendedErase = 0x44;

  /// 字节通道。
  final IspLink link;

  /// 擦除和写入边界。
  final Stm32IspOptions options;

  Stm32DeviceInfo? _deviceInfo;

  /// 当前识别结果；尚未同步时为 `null`。
  Stm32DeviceInfo? get deviceInfo => _deviceInfo;

  /// 同步并读取 bootloader 命令集与产品 ID。
  Future<Stm32DeviceInfo> connect({IspCancellationToken? cancellation}) async {
    final existing = _deviceInfo;
    if (existing != null) {
      return existing;
    }

    await link.clearInput();
    var synchronized = false;
    for (var attempt = 0; attempt < options.syncAttempts; attempt++) {
      cancellation?.throwIfCancelled();
      await link.write(Uint8List.fromList(<int>[synchronize]));
      try {
        final response = await link.readExact(1, timeout: options.syncTimeout);
        if (response.single == ack) {
          synchronized = true;
          break;
        }
        if (response.single != nack) {
          throw IspException(
            code: IspErrorCode.framing,
            message: '同步响应不是 ACK/NACK：0x${response.single.toRadixString(16)}',
          );
        }
      } on IspException catch (error) {
        if (error.code != IspErrorCode.timeout) {
          rethrow;
        }
      }
    }
    if (!synchronized) {
      throw const IspException(
        code: IspErrorCode.timeout,
        message: '未收到 STM32/GD32 bootloader 同步 ACK，请检查 BOOT0、复位和串口参数',
      );
    }

    cancellation?.throwIfCancelled();
    await _sendCommand(commandGet);
    final commandLength = (await _readBytes(1, 'Get 命令长度')).single;
    final version = (await _readBytes(1, 'Get 命令版本')).single;
    final commands = await _readBytes(commandLength, 'Get 命令列表');
    await _expectAck('Get 命令结束');

    cancellation?.throwIfCancelled();
    await _sendCommand(commandGetId);
    final idCountMinusOne = (await _readBytes(1, 'Get ID 长度')).single;
    final productId = await _readBytes(idCountMinusOne + 1, 'Get ID 数据');
    await _expectAck('Get ID 结束');

    final info = Stm32DeviceInfo(
      bootloaderVersion: version,
      commands: commands.toSet(),
      productId: productId,
    );
    if (!info.supports(commandWriteMemory) ||
        (!info.supports(commandErase) &&
            !info.supports(commandExtendedErase))) {
      throw const IspException(
        code: IspErrorCode.unsupportedCommand,
        message: '目标 bootloader 不支持 Flash 擦除或写入命令',
      );
    }
    _deviceInfo = info;
    return info;
  }

  /// 校验固件段是否全部位于配置的 Flash 范围内。
  void validateImage(FirmwareImage image) {
    for (final segment in image.segments) {
      if (segment.startAddress < options.flashStartAddress ||
          segment.endAddressExclusive > options.flashEndAddressExclusive) {
        throw IspException(
          code: IspErrorCode.addressOutOfRange,
          message:
              '固件段 0x${segment.startAddress.toRadixString(16)}–'
              '0x${(segment.endAddressExclusive - 1).toRadixString(16)} '
              '超出 Flash 范围',
        );
      }
    }
  }

  /// 在擦除前生成按 32 位字对齐的镜像，并重新校验填充后的范围。
  ///
  /// 相邻稀疏段可能落在同一个字内，必须先合并再写入，避免填充覆盖真实数据。
  /// 未定义字节填充为擦除态 0xFF；不跨越整字间隙分配大块内存。
  FirmwareImage prepareImage(FirmwareImage image) {
    validateImage(image);
    if (image.segments.every(
      (segment) =>
          segment.startAddress % 4 == 0 && segment.bytes.length % 4 == 0,
    )) {
      return image;
    }
    final normalized = <FirmwareSegment>[];
    var first = 0;
    while (first < image.segments.length) {
      final start = image.segments[first].startAddress & ~3;
      var end = (image.segments[first].endAddressExclusive + 3) & ~3;
      var next = first + 1;
      while (next < image.segments.length &&
          (image.segments[next].startAddress & ~3) <= end) {
        end = (image.segments[next].endAddressExclusive + 3) & ~3;
        next++;
      }
      if (start < options.flashStartAddress ||
          end > options.flashEndAddressExclusive) {
        throw const IspException(
          code: IspErrorCode.addressOutOfRange,
          message: '固件按字对齐并填充后超出 Flash 范围',
        );
      }
      final data = Uint8List(end - start)..fillRange(0, end - start, 0xFF);
      for (var index = first; index < next; index++) {
        final segment = image.segments[index];
        final offset = segment.startAddress - start;
        data.setRange(offset, offset + segment.bytes.length, segment.bytes);
      }
      normalized.add(FirmwareSegment(startAddress: start, bytes: data));
      first = next;
    }
    return FirmwareImage(segments: normalized, entryPoint: image.entryPoint);
  }

  /// 校验镜像最低地址处的应用向量表，返回 Go 命令需要的基址。
  ///
  /// HEX 的入口记录表示执行入口，不能代替向量表。未配置 SRAM 型号范围，
  /// 因此只检查 MSP 的基本格式；复位向量必须为镜像内的 Thumb 地址。
  int applicationVectorAddress(FirmwareImage image) {
    validateImage(image);
    final first = image.segments.first;
    if (first.startAddress % 4 != 0 || first.bytes.length < 8) {
      throw const IspException(
        code: IspErrorCode.framing,
        message: '应用向量表必须按字对齐且包含完整的 MSP 和复位向量',
      );
    }
    final vectors = ByteData.sublistView(first.bytes);
    final stack = vectors.getUint32(0, Endian.little);
    final reset = vectors.getUint32(4, Endian.little);
    final resetAddress = reset & ~1;
    if (stack == 0 ||
        stack == 0xFFFFFFFF ||
        stack % 4 != 0 ||
        reset & 1 == 0 ||
        !image.segments.any(
          (segment) =>
              resetAddress >= segment.startAddress &&
              resetAddress + 2 <= segment.endAddressExclusive,
        )) {
      throw const IspException(
        code: IspErrorCode.framing,
        message: '应用向量表无效：MSP 格式错误或复位向量未指向固件内的 Thumb 指令',
      );
    }
    _requireCommand(commandGo);
    return first.startAddress;
  }

  /// 执行全片擦除。
  Future<void> eraseAll({IspCancellationToken? cancellation}) async {
    cancellation?.throwIfCancelled();
    final info = _requireDeviceInfo();
    if (info.supports(commandExtendedErase)) {
      await _sendCommand(commandExtendedErase);
      await link.write(Uint8List.fromList(<int>[0xFF, 0xFF, 0x00]));
      await _expectAck('扩展全片擦除', timeout: options.eraseTimeout);
      return;
    }
    await _sendCommand(commandErase);
    await link.write(Uint8List.fromList(<int>[0xFF, 0x00]));
    await _expectAck('全片擦除', timeout: options.eraseTimeout);
  }

  /// 按 Intel HEX 段顺序写入固件。
  Future<void> writeImage(
    FirmwareImage image, {
    IspProgressCallback? onProgress,
    IspCancellationToken? cancellation,
  }) async {
    final prepared = prepareImage(image);
    final total = prepared.totalBytes;
    var completed = 0;
    onProgress?.call(
      IspProgress(
        phase: IspOperationPhase.writing,
        completedBytes: 0,
        totalBytes: total,
      ),
    );
    for (final segment in prepared.segments) {
      var offset = 0;
      while (offset < segment.bytes.length) {
        cancellation?.throwIfCancelled();
        final length = _remainingInBlock(segment.bytes.length, offset);
        final chunk = Uint8List.sublistView(
          segment.bytes,
          offset,
          offset + length,
        );
        await writeMemory(segment.startAddress + offset, chunk);
        offset += length;
        completed += length;
        onProgress?.call(
          IspProgress(
            phase: IspOperationPhase.writing,
            completedBytes: completed,
            totalBytes: total,
          ),
        );
      }
    }
  }

  /// 回读固件段并逐字节比较。
  Future<void> verifyImage(
    FirmwareImage image, {
    IspProgressCallback? onProgress,
    IspCancellationToken? cancellation,
  }) async {
    validateImage(image);
    final total = image.totalBytes;
    var completed = 0;
    onProgress?.call(
      IspProgress(
        phase: IspOperationPhase.verifying,
        completedBytes: 0,
        totalBytes: total,
      ),
    );
    for (final segment in image.segments) {
      var offset = 0;
      while (offset < segment.bytes.length) {
        cancellation?.throwIfCancelled();
        final length = _remainingInBlock(segment.bytes.length, offset);
        final expected = Uint8List.sublistView(
          segment.bytes,
          offset,
          offset + length,
        );
        final actual = await readMemory(segment.startAddress + offset, length);
        for (var index = 0; index < length; index++) {
          if (actual[index] != expected[index]) {
            throw IspException(
              code: IspErrorCode.framing,
              message:
                  '校验失败：地址 0x'
                  '${(segment.startAddress + offset + index).toRadixString(16)} '
                  '期望 0x${expected[index].toRadixString(16).padLeft(2, '0')}，'
                  '实际 0x${actual[index].toRadixString(16).padLeft(2, '0')}',
            );
          }
        }
        offset += length;
        completed += length;
        onProgress?.call(
          IspProgress(
            phase: IspOperationPhase.verifying,
            completedBytes: completed,
            totalBytes: total,
          ),
        );
      }
    }
  }

  /// 从指定地址启动程序。
  Future<void> go(int address, {IspCancellationToken? cancellation}) async {
    cancellation?.throwIfCancelled();
    if (address < 0 || address > 0xFFFFFFFF) {
      throw ArgumentError.value(address, 'address');
    }
    await _sendCommand(commandGo);
    await link.write(_encodeAddress(address));
    await _expectAck('Go 地址');
  }

  /// 读取最多 256 字节 Flash。
  Future<Uint8List> readMemory(int address, int length) async {
    if (length <= 0 || length > 256) {
      throw ArgumentError.value(length, 'length', '单次读取长度必须在 1 到 256 之间');
    }
    _requireCommand(commandReadMemory);
    await _sendCommand(commandReadMemory);
    await link.write(_encodeAddress(address));
    await _expectAck('Read Memory 地址');
    final lengthByte = (length - 1) & 0xFF;
    await link.write(Uint8List.fromList(<int>[lengthByte, lengthByte ^ 0xFF]));
    await _expectAck('Read Memory 长度');
    return _readBytes(length, 'Read Memory 数据');
  }

  /// 写入最多 256 字节 Flash；地址和长度必须按 32 位字对齐。
  Future<void> writeMemory(int address, Uint8List data) async {
    if (data.isEmpty || data.length > 256) {
      throw ArgumentError.value(
        data.length,
        'data.length',
        '单次写入长度必须在 1 到 256 之间',
      );
    }
    if (address % 4 != 0 || data.length % 4 != 0) {
      throw ArgumentError('Write Memory 地址和长度必须为 4 的倍数');
    }
    if (address < options.flashStartAddress ||
        address + data.length > options.flashEndAddressExclusive) {
      throw const IspException(
        code: IspErrorCode.addressOutOfRange,
        message: '写入范围超出 Flash 范围',
      );
    }
    _requireCommand(commandWriteMemory);
    await _sendCommand(commandWriteMemory);
    await link.write(_encodeAddress(address));
    await _expectAck('Write Memory 地址');
    final lengthByte = (data.length - 1) & 0xFF;
    var checksum = lengthByte;
    for (final byte in data) {
      checksum ^= byte;
    }
    final packet = Uint8List(data.length + 2)
      ..[0] = lengthByte
      ..setRange(1, 1 + data.length, data)
      ..[data.length + 1] = checksum;
    await link.write(packet);
    await _expectAck('Write Memory 数据');
  }

  Uint8List _encodeAddress(int address) {
    if (address < 0 || address > 0xFFFFFFFF) {
      throw ArgumentError.value(address, 'address');
    }
    final a0 = (address >> 24) & 0xFF;
    final a1 = (address >> 16) & 0xFF;
    final a2 = (address >> 8) & 0xFF;
    final a3 = address & 0xFF;
    return Uint8List.fromList(<int>[a0, a1, a2, a3, a0 ^ a1 ^ a2 ^ a3]);
  }

  Future<void> _sendCommand(int command) async {
    await link.write(Uint8List.fromList(<int>[command, command ^ 0xFF]));
    await _expectAck('命令 0x${command.toRadixString(16)}');
  }

  Future<void> _expectAck(String context, {Duration? timeout}) async {
    final response = await link.readExact(
      1,
      timeout: timeout ?? options.commandTimeout,
    );
    if (response.single == ack) {
      return;
    }
    if (response.single == nack) {
      throw IspException(code: IspErrorCode.nack, message: '$context 返回 NACK');
    }
    throw IspException(
      code: IspErrorCode.framing,
      message: '$context 返回未知响应 0x${response.single.toRadixString(16)}',
    );
  }

  Future<Uint8List> _readBytes(int length, String context) async {
    try {
      return await link.readExact(length, timeout: options.commandTimeout);
    } on IspException catch (error) {
      if (error.code == IspErrorCode.timeout) {
        throw IspException(
          code: IspErrorCode.timeout,
          message: '$context 超时',
          cause: error,
        );
      }
      rethrow;
    }
  }

  int _remainingInBlock(int totalLength, int offset) {
    final remaining = totalLength - offset;
    return remaining < options.blockSize ? remaining : options.blockSize;
  }

  Stm32DeviceInfo _requireDeviceInfo() {
    final info = _deviceInfo;
    if (info == null) {
      throw const IspException(
        code: IspErrorCode.deviceMismatch,
        message: '尚未识别目标设备',
      );
    }
    return info;
  }

  void _requireCommand(int command) {
    final info = _requireDeviceInfo();
    if (!info.supports(command)) {
      throw IspException(
        code: IspErrorCode.unsupportedCommand,
        message: '目标 bootloader 不支持命令 0x${command.toRadixString(16)}',
      );
    }
  }
}
