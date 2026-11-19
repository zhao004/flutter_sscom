import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读取 Oracle JSON 夹具。
Map<String, dynamic> _loadJson(String name) {
  final file = File('test/fixtures/legacy/$name');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// 校验十六进制字符串为非空或允许为空的字节序列。
void _expectHex(String value, {bool allowEmpty = false}) {
  final compact = value.replaceAll(RegExp(r'\s+'), '');
  if (allowEmpty && compact.isEmpty) {
    return;
  }
  expect(compact, isNotEmpty);
  expect(compact.length.isEven, isTrue, reason: value);
  expect(RegExp(r'^[0-9A-Fa-f]+$').hasMatch(compact), isTrue, reason: value);
}

void main() {
  group('Legacy Oracle 元数据', () {
    test('解包产物与原始文件具有独立哈希和完整分析规模', () {
      final metadata = _loadJson('oracle_metadata.json');
      final binary = metadata['binary'] as Map<String, dynamic>;

      expect(binary['sha256'], matches(RegExp(r'^[0-9A-F]{64}$')));
      expect(binary['unpackedSha256'], matches(RegExp(r'^[0-9A-F]{64}$')));
      expect(binary['sha256'], isNot(binary['unpackedSha256']));
      expect(binary['packedIdaFunctionCount'], 72);
      expect(binary['unpackedIdaFunctionCount'], greaterThan(72));
      expect(binary['hostExecution'], isFalse);
    });
  });

  group('校验算法夹具', () {
    test('覆盖 0 到 7 的校验模式且向量格式有效', () {
      final data = _loadJson('crc_vectors.json');
      final modes = (data['checksumModes'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final vectors = (data['vectors'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      expect(modes.map((mode) => mode['index']).toList(), <int>[
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
      ]);
      expect(vectors, isNotEmpty);
      expect(vectors.map((vector) => vector['checksumIndex']).toSet(), <int>{
        1,
        2,
        3,
        4,
        5,
        6,
        7,
      });
      for (final vector in vectors) {
        if (vector.containsKey('inputHex')) {
          _expectHex(vector['inputHex'] as String);
        }
        _expectHex(vector['expectedHex'] as String);
      }
    });

    test('包含标准 ASCII 校验基准值', () {
      final data = _loadJson('crc_vectors.json');
      final vectors = (data['vectors'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final expected = <int, String>{
        1: '37 4B',
        2: 'C3 31',
        3: '26 39 F4 CB',
        4: '23',
        5: 'DD',
        6: '31',
        7: '01 DD',
      };

      for (final entry in expected.entries) {
        final vector = vectors.firstWhere(
          (item) =>
              item['checksumIndex'] == entry.key &&
              item['inputAscii'] == '123456789',
        );
        expect(vector['expectedHex'], entry.value);
      }
    });
  });

  group('发送编码夹具', () {
    test('覆盖合法与非法 HEX 输入以及文本转义', () {
      final data = _loadJson('serialization_cases.json');
      final textCases = (data['textEscapeCases'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final hexCases = (data['hexInputCases'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      expect(textCases, isNotEmpty);
      expect(
        textCases.any((item) => item['id'] == 'unknown-escape-preserved'),
        isTrue,
      );
      for (final item in textCases) {
        _expectHex(item['expectedHex'] as String);
      }

      expect(
        hexCases.any((item) => item['expectedError'] == 'odd-nibble'),
        isTrue,
      );
      expect(
        hexCases.any((item) => item['expectedError'] == 'invalid-character'),
        isTrue,
      );
      for (final item in hexCases.where(
        (item) => item.containsKey('expectedHex'),
      )) {
        _expectHex(item['expectedHex'] as String, allowEmpty: true);
      }
    });
  });
}
