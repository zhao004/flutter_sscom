import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ascii_text_byte_encoder.dart';
import '../support/legacy_fixture.dart';

const _encoder = AsciiTextByteEncoder();

void main() {
  group('LegacyEscapeCodec', () {
    test('逐项匹配静态 Oracle 文本转义向量', () {
      final fixture = loadLegacyFixture('serialization_cases.json');
      final cases = (fixture['textEscapeCases'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      for (final item in cases) {
        final bytes = LegacyEscapeCodec.decode(
          item['input'] as String,
          textEncoder: _encoder,
        );
        expect(
          formatFixtureHex(bytes),
          item['expectedHex'],
          reason: item['id'] as String,
        );
      }
    });

    test('不完整或非法十六进制转义抛出结构化异常', () {
      expect(
        () => LegacyEscapeCodec.decode(r'A\x1', textEncoder: _encoder),
        throwsA(
          isA<EscapeInputException>()
              .having(
                (error) => error.code,
                'code',
                EscapeInputErrorCode.incompleteHexEscape,
              )
              .having((error) => error.inputIndex, 'inputIndex', 1),
        ),
      );
      expect(
        () => LegacyEscapeCodec.decode(r'A\xG1', textEncoder: _encoder),
        throwsA(
          isA<EscapeInputException>()
              .having(
                (error) => error.code,
                'code',
                EscapeInputErrorCode.invalidHexEscape,
              )
              .having((error) => error.inputIndex, 'inputIndex', 3),
        ),
      );
    });
  });

  group('LegacyHexCodec', () {
    test('逐项匹配静态 Oracle HEX 输入向量', () {
      final fixture = loadLegacyFixture('serialization_cases.json');
      final cases = (fixture['hexInputCases'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      for (final item in cases) {
        final id = item['id'] as String;
        final input = item['input'] as String;
        final expectedError = item['expectedError'] as String?;
        if (expectedError == null) {
          expect(
            formatFixtureHex(LegacyHexCodec.decode(input)),
            item['expectedHex'],
            reason: id,
          );
          continue;
        }

        expect(
          () => LegacyHexCodec.decode(input),
          throwsA(
            isA<HexInputException>().having(
              (error) => error.code,
              'code',
              _hexErrorCode(expectedError),
            ),
          ),
          reason: id,
        );
      }
    });

    test('记录非法字符在原始输入中的位置', () {
      expect(
        () => LegacyHexCodec.decode('0x12'),
        throwsA(
          isA<HexInputException>()
              .having(
                (error) => error.code,
                'code',
                HexInputErrorCode.invalidCharacter,
              )
              .having((error) => error.inputIndex, 'inputIndex', 1),
        ),
      );
    });
  });

  group('SendPayloadCodec', () {
    test('文本模式按需追加 CRLF', () {
      expect(
        SendPayloadCodec.encode(
          input: r'A\r',
          mode: SendInputMode.ansiText,
          textEncoder: _encoder,
          appendCrLf: true,
        ),
        orderedEquals(<int>[0x41, 0x0D, 0x0D, 0x0A]),
      );
    });

    test('HEX 模式忽略 CRLF 参数', () {
      expect(
        SendPayloadCodec.encode(
          input: '41',
          mode: SendInputMode.hex,
          textEncoder: _encoder,
          appendCrLf: true,
        ),
        orderedEquals(<int>[0x41]),
      );
    });

    test('文本模式未启用 CRLF 时保持解析结果', () {
      final bytes = SendPayloadCodec.encode(
        input: 'AB',
        mode: SendInputMode.ansiText,
        textEncoder: _encoder,
      );

      expect(bytes, orderedEquals(<int>[0x41, 0x42]));
    });
  });
}

HexInputErrorCode _hexErrorCode(String id) {
  return switch (id) {
    'odd-nibble' => HexInputErrorCode.oddNibble,
    'invalid-character' => HexInputErrorCode.invalidCharacter,
    _ => throw ArgumentError.value(id, 'id', '未知 HEX 错误类型'),
  };
}
