import 'dart:typed_data';

import '../escape_codec/legacy_escape_codec.dart';
import '../escape_codec/text_byte_encoder.dart';
import '../hex_codec/legacy_hex_codec.dart';

/// 发送输入模式。
enum SendInputMode {
  /// ANSI 文本和反斜杠转义模式。
  ansiText,

  /// HEX 字节输入模式。
  hex,
}

/// 将 UI 输入编码为待发送字节。
final class SendPayloadCodec {
  const SendPayloadCodec._();

  /// 编码发送输入。
  ///
  /// HEX 模式忽略 [appendCrLf]；文本模式在转义解析后追加 CRLF。调用方可在
  /// 返回结果上继续执行校验插入和发送。
  static Uint8List encode({
    required String input,
    required SendInputMode mode,
    required TextByteEncoder textEncoder,
    bool appendCrLf = false,
  }) {
    if (mode == SendInputMode.hex) {
      return LegacyHexCodec.decode(input);
    }

    final payload = LegacyEscapeCodec.decode(input, textEncoder: textEncoder);
    if (!appendCrLf) {
      return payload;
    }
    return (BytesBuilder(copy: false)
          ..add(payload)
          ..add(const <int>[0x0D, 0x0A]))
        .takeBytes();
  }
}
