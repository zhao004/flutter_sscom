import 'dart:typed_data';

/// 将用户可见文本转换为传输字节的可注入编码器。
abstract interface class TextByteEncoder {
  /// 编码一个文本片段。
  ///
  /// 实现必须返回独立字节列表，不得修改输入文本。
  Uint8List encode(String value);
}
