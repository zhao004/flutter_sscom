import 'dart:typed_data';

import 'text_byte_encoder.dart';

/// 文本转义解析失败的错误类型。
enum EscapeInputErrorCode {
  /// `\x` 后不足两个字符。
  incompleteHexEscape,

  /// `\x` 后包含非十六进制字符。
  invalidHexEscape,
}

/// 表示文本转义无法安全转换为字节。
final class EscapeInputException implements Exception {
  /// 创建转义输入异常。
  const EscapeInputException({
    required this.code,
    required this.inputIndex,
    required this.message,
  });

  /// 稳定错误类型。
  final EscapeInputErrorCode code;

  /// 原始输入中的 UTF-16 code unit 索引。
  final int inputIndex;

  /// 面向开发者的错误说明。
  final String message;

  @override
  String toString() {
    return 'EscapeInputException(${code.name}, inputIndex: $inputIndex): '
        '$message';
  }
}

/// 按旧版 SSCOM 规则解析文本转义。
final class LegacyEscapeCodec {
  const LegacyEscapeCodec._();

  /// 将文本转义转换为字节。
  ///
  /// 普通文本片段由 [textEncoder] 编码。未知转义和尾部孤立反斜杠保持原样，
  /// 与旧版静态路径一致。不完整或非法 `\xHH` 会被拒绝，这是明确的安全强化。
  static Uint8List decode(
    String input, {
    required TextByteEncoder textEncoder,
  }) {
    final output = BytesBuilder(copy: false);
    final literal = StringBuffer();

    void flushLiteral() {
      if (literal.isEmpty) {
        return;
      }
      output.add(textEncoder.encode(literal.toString()));
      literal.clear();
    }

    for (var index = 0; index < input.length; index++) {
      final char = input[index];
      if (char != r'\') {
        literal.write(char);
        continue;
      }

      flushLiteral();
      if (index + 1 >= input.length) {
        output.add(textEncoder.encode(r'\'));
        break;
      }

      final escapeCode = input[index + 1];
      final namedByte = _namedEscapes[escapeCode];
      if (namedByte != null) {
        output.addByte(namedByte);
        index++;
        continue;
      }

      if (escapeCode == 'x') {
        final firstIndex = index + 2;
        final secondIndex = index + 3;
        if (secondIndex >= input.length) {
          throw EscapeInputException(
            code: EscapeInputErrorCode.incompleteHexEscape,
            inputIndex: index,
            message: r'\x 后必须紧跟两个十六进制字符',
          );
        }

        final high = _hexValue(input.codeUnitAt(firstIndex));
        if (high == null) {
          throw EscapeInputException(
            code: EscapeInputErrorCode.invalidHexEscape,
            inputIndex: firstIndex,
            message: r'\x 后必须是两个十六进制字符',
          );
        }
        final low = _hexValue(input.codeUnitAt(secondIndex));
        if (low == null) {
          throw EscapeInputException(
            code: EscapeInputErrorCode.invalidHexEscape,
            inputIndex: secondIndex,
            message: r'\x 后必须是两个十六进制字符',
          );
        }

        output.addByte((high << 4) | low);
        index += 3;
        continue;
      }

      output.add(textEncoder.encode('\\$escapeCode'));
      index++;
    }

    flushLiteral();
    return output.takeBytes();
  }

  static const Map<String, int> _namedEscapes = <String, int>{
    'r': 0x0D,
    'n': 0x0A,
    't': 0x09,
    'v': 0x0B,
    'b': 0x08,
    'f': 0x0C,
    'a': 0x07,
    '0': 0x00,
    r'\': 0x5C,
  };

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
