import 'dart:typed_data';

import 'firmware_image.dart';

/// Intel HEX 解析失败。
final class IntelHexFormatException implements Exception {
  /// 创建解析异常。
  const IntelHexFormatException(this.message, {this.lineNumber});

  /// 面向用户的错误说明。
  final String message;

  /// 出错的一基行号；文件级错误时为空。
  final int? lineNumber;

  @override
  String toString() {
    final location = lineNumber == null ? '' : '第 $lineNumber 行：';
    return 'Intel HEX 格式错误，$location$message';
  }
}

/// 严格 Intel HEX 解析器。
///
/// 支持数据、文件结束、扩展段地址、起始段地址、扩展线性地址和起始线性地址
/// 记录。解析器拒绝非法 checksum、截断记录、重叠数据、未知记录、缺失 EOF 以及
/// 超出 32 位地址空间的数据。
final class IntelHexParser {
  /// 创建解析器。
  const IntelHexParser({this.maxSourceCharacters = 16 * 1024 * 1024});

  /// 允许解析的原始文本字符上限。
  final int maxSourceCharacters;

  /// 解析 Intel HEX 文本。
  FirmwareImage parse(String source) {
    if (source.length > maxSourceCharacters) {
      throw const IntelHexFormatException('文件超过允许的 16 MiB 文本上限');
    }

    final records = <_ParsedSegment>[];
    var extendedBase = 0;
    int? entryPoint;
    var eofSeen = false;
    final lines = source.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final lineNumber = index + 1;
      final rawLine = lines[index].trim();
      if (rawLine.isEmpty) {
        continue;
      }
      if (eofSeen) {
        throw IntelHexFormatException(
          'EOF 记录之后不能再出现数据',
          lineNumber: lineNumber,
        );
      }
      if (!rawLine.startsWith(':')) {
        throw IntelHexFormatException('记录必须以冒号开始', lineNumber: lineNumber);
      }

      final encoded = rawLine.substring(1);
      if (encoded.length.isOdd) {
        throw IntelHexFormatException('HEX 字符数必须为偶数', lineNumber: lineNumber);
      }
      final bytes = Uint8List(encoded.length ~/ 2);
      for (var byteIndex = 0; byteIndex < bytes.length; byteIndex++) {
        final start = byteIndex * 2;
        final value = int.tryParse(
          encoded.substring(start, start + 2),
          radix: 16,
        );
        if (value == null) {
          throw IntelHexFormatException('包含非十六进制字符', lineNumber: lineNumber);
        }
        bytes[byteIndex] = value;
      }
      if (bytes.length < 5) {
        throw IntelHexFormatException('记录长度不足', lineNumber: lineNumber);
      }

      final byteCount = bytes[0];
      if (bytes.length != byteCount + 5) {
        throw IntelHexFormatException(
          '字节计数字段为 $byteCount，但记录实际包含 ${bytes.length - 5} 个数据字节',
          lineNumber: lineNumber,
        );
      }
      var checksum = 0;
      for (final byte in bytes) {
        checksum = (checksum + byte) & 0xFF;
      }
      if (checksum != 0) {
        throw IntelHexFormatException('checksum 校验失败', lineNumber: lineNumber);
      }

      final recordAddress = (bytes[1] << 8) | bytes[2];
      final recordType = bytes[3];
      final data = Uint8List.sublistView(bytes, 4, 4 + byteCount);
      switch (recordType) {
        case 0x00:
          if (data.isEmpty) {
            throw IntelHexFormatException('数据记录不能为空', lineNumber: lineNumber);
          }
          final absoluteAddress = extendedBase + recordAddress;
          if (absoluteAddress > 0xFFFFFFFF ||
              absoluteAddress + data.length > 0x100000000) {
            throw IntelHexFormatException(
              '数据地址超出 32 位范围',
              lineNumber: lineNumber,
            );
          }
          records.add(
            _ParsedSegment(
              startAddress: absoluteAddress,
              bytes: Uint8List.fromList(data),
            ),
          );
        case 0x01:
          if (byteCount != 0 || recordAddress != 0) {
            throw IntelHexFormatException(
              'EOF 记录必须为零长度且地址为零',
              lineNumber: lineNumber,
            );
          }
          eofSeen = true;
        case 0x02:
          _requireLength(data, 2, lineNumber, '扩展段地址');
          extendedBase = ((data[0] << 8) | data[1]) << 4;
        case 0x03:
          _requireLength(data, 4, lineNumber, '起始段地址');
          final value =
              (((data[0] << 8) | data[1]) << 4) + ((data[2] << 8) | data[3]);
          entryPoint = _mergeEntryPoint(entryPoint, value, lineNumber);
        case 0x04:
          _requireLength(data, 2, lineNumber, '扩展线性地址');
          extendedBase = ((data[0] << 8) | data[1]) << 16;
        case 0x05:
          _requireLength(data, 4, lineNumber, '起始线性地址');
          final value =
              (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
          entryPoint = _mergeEntryPoint(entryPoint, value, lineNumber);
        default:
          throw IntelHexFormatException(
            '不支持的记录类型 0x${recordType.toRadixString(16).padLeft(2, '0')}',
            lineNumber: lineNumber,
          );
      }
    }

    if (!eofSeen) {
      throw const IntelHexFormatException('缺少 EOF 记录');
    }
    if (records.isEmpty) {
      throw const IntelHexFormatException('文件中没有固件数据');
    }

    records.sort(
      (left, right) => left.startAddress.compareTo(right.startAddress),
    );
    final merged = <_ParsedSegment>[];
    for (final record in records) {
      if (merged.isEmpty) {
        merged.add(record);
        continue;
      }
      final previous = merged.last;
      if (record.startAddress < previous.endAddressExclusive) {
        throw IntelHexFormatException(
          '数据地址 0x${record.startAddress.toRadixString(16)} 与已有记录重叠',
        );
      }
      if (record.startAddress == previous.endAddressExclusive) {
        final combined = Uint8List(previous.bytes.length + record.bytes.length)
          ..setRange(0, previous.bytes.length, previous.bytes)
          ..setRange(
            previous.bytes.length,
            previous.bytes.length + record.bytes.length,
            record.bytes,
          );
        merged[merged.length - 1] = _ParsedSegment(
          startAddress: previous.startAddress,
          bytes: combined,
        );
      } else {
        merged.add(record);
      }
    }

    return FirmwareImage(
      segments: merged
          .map(
            (record) => FirmwareSegment(
              startAddress: record.startAddress,
              bytes: record.bytes,
            ),
          )
          .toList(growable: false),
      entryPoint: entryPoint,
    );
  }

  void _requireLength(
    Uint8List data,
    int expected,
    int lineNumber,
    String recordName,
  ) {
    if (data.length != expected) {
      throw IntelHexFormatException(
        '$recordName记录必须包含 $expected 个数据字节',
        lineNumber: lineNumber,
      );
    }
  }

  int _mergeEntryPoint(int? existing, int value, int lineNumber) {
    if (existing != null && existing != value) {
      throw IntelHexFormatException('存在互相冲突的入口地址记录', lineNumber: lineNumber);
    }
    return value;
  }
}

/// 解析 Intel HEX 文本。
FirmwareImage parseIntelHex(String source) =>
    const IntelHexParser().parse(source);

final class _ParsedSegment {
  const _ParsedSegment({required this.startAddress, required this.bytes});

  final int startAddress;
  final Uint8List bytes;

  int get endAddressExclusive => startAddress + bytes.length;
}
