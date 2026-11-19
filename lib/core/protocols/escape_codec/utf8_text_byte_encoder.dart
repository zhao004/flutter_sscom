import 'dart:convert';
import 'dart:typed_data';

import 'text_byte_encoder.dart';

/// 使用 UTF-8 编码用户文本。
final class Utf8TextByteEncoder implements TextByteEncoder {
  /// 创建无状态 UTF-8 编码器。
  const Utf8TextByteEncoder();

  @override
  Uint8List encode(String value) => Uint8List.fromList(utf8.encode(value));
}
