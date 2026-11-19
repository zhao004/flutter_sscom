import 'dart:typed_data';

import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/legacy_fixture.dart';

void main() {
  group('LegacyChecksum', () {
    test('旧版索引与 0 到 7 的校验模式一一对应', () {
      expect(
        LegacyChecksumMode.values.map((mode) => mode.legacyIndex),
        orderedEquals(<int>[0, 1, 2, 3, 4, 5, 6, 7]),
      );
      expect(() => LegacyChecksumMode.fromLegacyIndex(8), throwsArgumentError);
    });

    test('逐项匹配静态 Oracle 校验向量', () {
      final fixture = loadLegacyFixture('crc_vectors.json');
      final vectors = (fixture['vectors'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      for (final vector in vectors) {
        final mode = LegacyChecksumMode.fromLegacyIndex(
          vector['checksumIndex'] as int,
        );
        final input = switch (vector['inputAscii']) {
          final String ascii => Uint8List.fromList(ascii.codeUnits),
          _ => parseFixtureHex(vector['inputHex'] as String),
        };

        expect(
          formatFixtureHex(LegacyChecksum.calculate(mode, input)),
          vector['expectedHex'],
          reason: vector['id'] as String,
        );
      }
    });

    test('无校验返回空字节且不修改输入', () {
      final input = Uint8List.fromList(<int>[0x01, 0x02, 0x03]);
      final checksum = LegacyChecksum.calculate(LegacyChecksumMode.none, input);

      expect(checksum, isEmpty);
      expect(input, orderedEquals(<int>[0x01, 0x02, 0x03]));
    });
  });
}
