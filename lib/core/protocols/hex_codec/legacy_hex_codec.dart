import 'dart:typed_data';

/// HEX 输入解析失败的错误类型。
enum HexInputErrorCode {
  /// 输入包含非十六进制字符。
  invalidCharacter,

  /// 去除空白后只剩奇数个半字节。
  oddNibble,
}

/// 表示旧版 HEX 输入无法安全转换为字节。
final class HexInputException implements Exception {
  /// 创建 HEX 输入异常。
  const HexInputException({
    required this.code,
    required this.inputIndex,
    required this.message,
  });

  /// 稳定错误类型。
  final HexInputErrorCode code;

  /// 原始输入中的 UTF-16 code unit 索引。
  final int inputIndex;

  /// 面向开发者的错误说明。
  final String message;

  @override
  String toString() {
    return 'HexInputException(${code.name}, inputIndex: $inputIndex): $message';
  }
}

/// 按 SSCOM 规则解析 HEX 输入。
final class LegacyHexCodec {
  const LegacyHexCodec._();

  /// 将 HEX 文本转换为字节。
  ///
  /// 只忽略半角空格、CR 和 LF；其他字符必须为 `0-9`、`A-F` 或 `a-f`。
  /// 空输入返回空字节列表。
  static Uint8List decode(String input) {
    final bytes = <int>[];
    int? highNibble;
    var highNibbleIndex = -1;

    for (var index = 0; index < input.length; index++) {
      final codeUnit = input.codeUnitAt(index);
      if (codeUnit == 0x20 || codeUnit == 0x0D || codeUnit == 0x0A) {
        continue;
      }

      final nibble = _hexValue(codeUnit);
      if (nibble == null) {
        throw HexInputException(
          code: HexInputErrorCode.invalidCharacter,
          inputIndex: index,
          message: '只允许 0-9、A-F、a-f、空格、CR 和 LF',
        );
      }

      if (highNibble == null) {
        highNibble = nibble;
        highNibbleIndex = index;
      } else {
        bytes.add((highNibble << 4) | nibble);
        highNibble = null;
        highNibbleIndex = -1;
      }
    }

    if (highNibble != null) {
      throw HexInputException(
        code: HexInputErrorCode.oddNibble,
        inputIndex: highNibbleIndex,
        message: 'HEX 数据必须按两个半字节组成一个字节',
      );
    }
    return Uint8List.fromList(bytes);
  }

  static int? _hexValue(int codeUnit) {
    if (codeUnit >= 0x30 && codeUnit <= 0x39) {
      return codeUnit - 0x30;
    }
    if (codeUnit >= 0x41 && codeUnit <= 0x46) {
      return codeUnit - 0x41 + 10;
    }
    if (codeUnit >= 0x61 && codeUnit <= 0x66) {
      return codeUnit - 0x61 + 10;
    }
    return null;
  }
}
