import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 读取 `test/fixtures/legacy` 下的 JSON 夹具。
Map<String, dynamic> loadLegacyFixture(String name) {
  final file = File('test/fixtures/legacy/$name');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// 将带空白的十六进制夹具解析为字节。
Uint8List parseFixtureHex(String value) {
  final compact = value.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) {
    return Uint8List(0);
  }
  if (compact.length.isOdd) {
    throw FormatException('十六进制夹具必须包含偶数个半字节', value);
  }

  final bytes = Uint8List(compact.length ~/ 2);
  for (var index = 0; index < bytes.length; index++) {
    final byte = int.tryParse(
      compact.substring(index * 2, index * 2 + 2),
      radix: 16,
    );
    if (byte == null) {
      throw FormatException('十六进制夹具包含非法字符', value);
    }
    bytes[index] = byte;
  }
  return bytes;
}

/// 将字节格式化为大写、空格分隔的十六进制文本，便于和夹具比对。
String formatFixtureHex(Uint8List bytes) {
  return bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}
