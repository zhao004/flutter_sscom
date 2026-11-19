import 'dart:typed_data';

import 'package:flutter_sscom/core/protocols/protocols.dart';

/// 测试专用 ASCII 编码器，遇到非 ASCII 字符时立即失败。
final class AsciiTextByteEncoder implements TextByteEncoder {
  const AsciiTextByteEncoder();

  @override
  Uint8List encode(String value) {
    final result = Uint8List(value.length);
    for (var index = 0; index < value.length; index++) {
      final codeUnit = value.codeUnitAt(index);
      if (codeUnit > 0x7F) {
        throw ArgumentError.value(value, 'value', '测试编码器只支持 ASCII');
      }
      result[index] = codeUnit;
    }
    return result;
  }
}
