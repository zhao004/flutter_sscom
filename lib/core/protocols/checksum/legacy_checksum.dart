import 'dart:typed_data';

/// 旧版 SSCOM `N1060` 使用的校验模式及稳定索引。
enum LegacyChecksumMode {
  /// 不追加校验。
  none(0),

  /// CRC-16/MODBUS，输出低字节、高字节。
  modbusCrc16(1),

  /// CRC-16/CCITT，初值为 0，输出低字节、高字节。
  ccittCrc16(2),

  /// 标准反射 CRC-32，输出小端四字节。
  crc32(3),

  /// 8 位累加和的二补数。
  add8TwosComplement(4),

  /// 8 位累加和。
  add8(5),

  /// 8 位异或和。
  xor8(6),

  /// 16 位累加和，输出高字节、低字节。
  add16(7);

  const LegacyChecksumMode(this.legacyIndex);

  /// 旧版组合框中的索引。
  final int legacyIndex;

  /// 按旧版索引查找校验模式。
  ///
  /// 不支持的索引会抛出 [ArgumentError]。
  static LegacyChecksumMode fromLegacyIndex(int index) {
    for (final mode in values) {
      if (mode.legacyIndex == index) {
        return mode;
      }
    }
    throw ArgumentError.value(index, 'index', '不支持的旧版校验索引');
  }
}

/// 按旧版字节序和初值计算校验值。
final class LegacyChecksum {
  const LegacyChecksum._();

  static final Uint32List _crc32Table = _createCrc32Table();

  /// 计算指定模式的校验字节。
  ///
  /// [data] 不会被修改；返回值是新分配的字节序列。
  static Uint8List calculate(LegacyChecksumMode mode, Uint8List data) {
    return switch (mode) {
      LegacyChecksumMode.none => Uint8List(0),
      LegacyChecksumMode.modbusCrc16 => _modbusCrc16(data),
      LegacyChecksumMode.ccittCrc16 => _ccittCrc16(data),
      LegacyChecksumMode.crc32 => _crc32(data),
      LegacyChecksumMode.add8TwosComplement => Uint8List.fromList(<int>[
        (-(_sum8(data))) & 0xFF,
      ]),
      LegacyChecksumMode.add8 => Uint8List.fromList(<int>[_sum8(data)]),
      LegacyChecksumMode.xor8 => Uint8List.fromList(<int>[_xor8(data)]),
      LegacyChecksumMode.add16 => _add16(data),
    };
  }

  static Uint8List _modbusCrc16(Uint8List data) {
    var crc = 0xFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
      }
    }
    return Uint8List.fromList(<int>[crc & 0xFF, (crc >> 8) & 0xFF]);
  }

  static Uint8List _ccittCrc16(Uint8List data) {
    var crc = 0;
    for (final byte in data) {
      var word = (byte << 8) & 0xFFFF;
      for (var bit = 0; bit < 8; bit++) {
        crc = ((word ^ crc) & 0x8000) != 0
            ? ((crc << 1) ^ 0x1021) & 0xFFFF
            : (crc << 1) & 0xFFFF;
        word = (word << 1) & 0xFFFF;
      }
    }
    return Uint8List.fromList(<int>[crc & 0xFF, (crc >> 8) & 0xFF]);
  }

  static Uint8List _crc32(Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = (crc >> 8) ^ _crc32Table[(crc ^ byte) & 0xFF];
      crc &= 0xFFFFFFFF;
    }
    final result = (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
    return Uint8List.fromList(<int>[
      result & 0xFF,
      (result >> 8) & 0xFF,
      (result >> 16) & 0xFF,
      (result >> 24) & 0xFF,
    ]);
  }

  static Uint8List _add16(Uint8List data) {
    final sum = data.fold<int>(0, (value, byte) => value + byte) & 0xFFFF;
    return Uint8List.fromList(<int>[(sum >> 8) & 0xFF, sum & 0xFF]);
  }

  static int _sum8(Uint8List data) {
    return data.fold<int>(0, (value, byte) => value + byte) & 0xFF;
  }

  static int _xor8(Uint8List data) {
    return data.fold<int>(0, (value, byte) => value ^ byte);
  }

  static Uint32List _createCrc32Table() {
    final table = Uint32List(256);
    for (var index = 0; index < table.length; index++) {
      var value = index;
      for (var bit = 0; bit < 8; bit++) {
        value = (value & 1) != 0 ? (value >> 1) ^ 0xEDB88320 : value >> 1;
      }
      table[index] = value & 0xFFFFFFFF;
    }
    return table;
  }
}
