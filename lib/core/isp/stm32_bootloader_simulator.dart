import 'dart:typed_data';

import 'isp_protocol.dart';

/// 内存中的 STM32/GD32 UART bootloader 模拟器。
///
/// 模拟器实现 AN3155 所需的最小命令子集，用于在没有硬件时验证同步、识别、
/// 擦除、写入、回读校验和 Go 命令序列。它不模拟真实串口时序或电气复位。
final class Stm32BootloaderSimulator implements IspLink {
  /// 创建模拟器。
  Stm32BootloaderSimulator({
    this.flashStartAddress = 0x08000000,
    this.flashSizeBytes = 64 * 1024,
    this.productId = const <int>[0x04, 0x10],
    this.bootloaderVersion = 0x31,
    this.commands = const <int>[0x00, 0x01, 0x02, 0x11, 0x21, 0x31, 0x43, 0x44],
  }) : _flash = Uint8List(flashSizeBytes)..fillRange(0, flashSizeBytes, 0xFF);

  /// 模拟 Flash 起始地址。
  final int flashStartAddress;

  /// 模拟 Flash 容量。
  final int flashSizeBytes;

  /// 产品 ID 响应。
  final List<int> productId;

  /// bootloader 版本。
  final int bootloaderVersion;

  /// 支持的命令集合。
  final List<int> commands;

  final List<int> _input = <int>[];
  final List<int> _output = <int>[];
  Uint8List _flash;
  _SimulatorMode _mode = _SimulatorMode.command;
  int _writeAddress = 0;
  int _writeLength = 0;
  final List<int> _writeData = <int>[];
  int _readAddress = 0;
  int _readLength = 0;
  int? _startedAddress;
  bool _closed = false;
  bool _dtr = false;
  bool _rts = false;

  /// 最近一次 Go 地址。
  int? get startedAddress => _startedAddress;

  /// DTR 当前状态。
  bool get dtr => _dtr;

  /// RTS 当前状态。
  bool get rts => _rts;

  /// 返回模拟 Flash 的独立副本。
  Uint8List readFlash() => Uint8List.fromList(_flash);

  @override
  Future<void> write(Uint8List bytes) async {
    _ensureOpen();
    _input.addAll(bytes);
    _pump();
  }

  @override
  Future<Uint8List> readExact(int length, {required Duration timeout}) async {
    _ensureOpen();
    if (_output.length < length) {
      throw const IspException(
        code: IspErrorCode.timeout,
        message: '模拟 bootloader 没有足够响应数据',
      );
    }
    final result = Uint8List.fromList(_output.take(length).toList());
    _output.removeRange(0, length);
    return result;
  }

  @override
  Future<void> clearInput() async {
    _ensureOpen();
    _input.clear();
    _output.clear();
  }

  @override
  Future<void> setDtr(bool enabled) async {
    _ensureOpen();
    _dtr = enabled;
  }

  @override
  Future<void> setRts(bool enabled) async {
    _ensureOpen();
    _rts = enabled;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _input.clear();
    _output.clear();
  }

  void _pump() {
    var progressed = true;
    while (progressed && !_closed) {
      progressed = switch (_mode) {
        _SimulatorMode.command => _pumpCommand(),
        _SimulatorMode.eraseStandard => _pumpEraseStandard(),
        _SimulatorMode.eraseExtended => _pumpEraseExtended(),
        _SimulatorMode.writeAddress => _pumpWriteAddress(),
        _SimulatorMode.writeLength => _pumpWriteLength(),
        _SimulatorMode.writeData => _pumpWriteData(),
        _SimulatorMode.readAddress => _pumpReadAddress(),
        _SimulatorMode.readLength => _pumpReadLength(),
        _SimulatorMode.goAddress => _pumpGoAddress(),
      };
    }
  }

  bool _pumpCommand() {
    if (_input.isEmpty) {
      return false;
    }
    if (_input.first == 0x7F) {
      _input.removeAt(0);
      _output.add(0x79);
      return true;
    }
    if (_input.length < 2) {
      return false;
    }
    final command = _input.removeAt(0);
    final complement = _input.removeAt(0);
    if ((command ^ complement) != 0xFF || !commands.contains(command)) {
      _output.add(0x1F);
      return true;
    }
    switch (command) {
      case 0x00:
        _output
          ..add(0x79)
          ..add(commands.length)
          ..add(bootloaderVersion)
          ..addAll(commands)
          ..add(0x79);
      case 0x01:
        _output
          ..add(0x79)
          ..add(bootloaderVersion)
          ..add(0x00)
          ..add(0x00)
          ..add(0x79);
      case 0x02:
        final count = productId.isEmpty ? 1 : productId.length;
        _output
          ..add(0x79)
          ..add(count - 1);
        if (productId.isEmpty) {
          _output.add(0x00);
        } else {
          _output.addAll(productId);
        }
        _output.add(0x79);
      case 0x43:
        _output.add(0x79);
        _mode = _SimulatorMode.eraseStandard;
      case 0x44:
        _output.add(0x79);
        _mode = _SimulatorMode.eraseExtended;
      case 0x31:
        _output.add(0x79);
        _mode = _SimulatorMode.writeAddress;
      case 0x11:
        _output.add(0x79);
        _mode = _SimulatorMode.readAddress;
      case 0x21:
        _output.add(0x79);
        _mode = _SimulatorMode.goAddress;
      default:
        _output.add(0x1F);
    }
    return true;
  }

  bool _pumpEraseStandard() {
    if (_input.length < 2) {
      return false;
    }
    final first = _input.removeAt(0);
    final checksum = _input.removeAt(0);
    if (first == 0xFF && checksum == 0x00) {
      _eraseFlash();
      _output.add(0x79);
    } else {
      _output.add(0x1F);
    }
    _mode = _SimulatorMode.command;
    return true;
  }

  bool _pumpEraseExtended() {
    if (_input.length < 3) {
      return false;
    }
    final bytes = <int>[
      _input.removeAt(0),
      _input.removeAt(0),
      _input.removeAt(0),
    ];
    final checksum = bytes[0] ^ bytes[1] ^ bytes[2];
    if (bytes[0] == 0xFF && bytes[1] == 0xFF && checksum == 0x00) {
      _eraseFlash();
      _output.add(0x79);
    } else {
      _output.add(0x1F);
    }
    _mode = _SimulatorMode.command;
    return true;
  }

  bool _pumpWriteAddress() {
    if (_input.length < 5) {
      return false;
    }
    final packet = Uint8List.fromList(_input.take(5).toList());
    _input.removeRange(0, 5);
    if (!_validAddressPacket(packet)) {
      _output.add(0x1F);
      _mode = _SimulatorMode.command;
      return true;
    }
    _writeAddress = _decodeAddress(packet);
    _output.add(0x79);
    _mode = _SimulatorMode.writeLength;
    return true;
  }

  bool _pumpWriteLength() {
    if (_input.isEmpty) {
      return false;
    }
    final lengthByte = _input.removeAt(0);
    _writeLength = lengthByte + 1;
    _writeData.clear();
    _mode = _SimulatorMode.writeData;
    return true;
  }

  bool _pumpWriteData() {
    if (_input.length < _writeLength + 1) {
      return false;
    }
    final data = Uint8List.fromList(
      _input.take(_writeLength).toList(growable: false),
    );
    final checksum = _input.removeAt(_writeLength);
    _input.removeRange(0, _writeLength);
    var expected = (_writeLength - 1) & 0xFF;
    for (final byte in data) {
      expected ^= byte;
    }
    if (checksum != expected || !_isWritable(_writeAddress, data.length)) {
      _output.add(0x1F);
      _mode = _SimulatorMode.command;
      return true;
    }
    final offset = _writeAddress - flashStartAddress;
    _flash.setRange(offset, offset + data.length, data);
    _output.add(0x79);
    _mode = _SimulatorMode.command;
    return true;
  }

  bool _pumpReadAddress() {
    if (_input.length < 5) {
      return false;
    }
    final packet = Uint8List.fromList(_input.take(5).toList());
    _input.removeRange(0, 5);
    if (!_validAddressPacket(packet)) {
      _output.add(0x1F);
      _mode = _SimulatorMode.command;
      return true;
    }
    _readAddress = _decodeAddress(packet);
    _output.add(0x79);
    _mode = _SimulatorMode.readLength;
    return true;
  }

  bool _pumpReadLength() {
    if (_input.length < 2) {
      return false;
    }
    final lengthByte = _input.removeAt(0);
    final checksum = _input.removeAt(0);
    _readLength = lengthByte + 1;
    if (checksum != (lengthByte ^ 0xFF) ||
        !_isReadable(_readAddress, _readLength)) {
      _output.add(0x1F);
      _mode = _SimulatorMode.command;
      return true;
    }
    _output.add(0x79);
    final offset = _readAddress - flashStartAddress;
    _output.addAll(_flash.sublist(offset, offset + _readLength));
    _mode = _SimulatorMode.command;
    return true;
  }

  bool _pumpGoAddress() {
    if (_input.length < 5) {
      return false;
    }
    final packet = Uint8List.fromList(_input.take(5).toList());
    _input.removeRange(0, 5);
    if (!_validAddressPacket(packet)) {
      _output.add(0x1F);
    } else {
      _startedAddress = _decodeAddress(packet);
      _output.add(0x79);
    }
    _mode = _SimulatorMode.command;
    return true;
  }

  void _eraseFlash() {
    _flash = Uint8List(flashSizeBytes)..fillRange(0, flashSizeBytes, 0xFF);
  }

  bool _validAddressPacket(Uint8List packet) {
    var checksum = 0;
    for (final byte in packet) {
      checksum ^= byte;
    }
    return checksum == 0;
  }

  int _decodeAddress(Uint8List packet) =>
      (packet[0] << 24) | (packet[1] << 16) | (packet[2] << 8) | packet[3];

  bool _isWritable(int address, int length) =>
      address >= flashStartAddress &&
      address + length <= flashStartAddress + flashSizeBytes;

  bool _isReadable(int address, int length) => _isWritable(address, length);

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Stm32BootloaderSimulator 已关闭');
    }
  }
}

enum _SimulatorMode {
  command,
  eraseStandard,
  eraseExtended,
  writeAddress,
  writeLength,
  writeData,
  readAddress,
  readLength,
  goAddress,
}
