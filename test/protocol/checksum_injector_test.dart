import 'dart:typed_data';

import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChecksumInjector', () {
    test('无尾部排除时在消息末尾追加校验', () {
      final payload = Uint8List.fromList(<int>[0x01, 0x02, 0x03]);
      final result = ChecksumInjector.apply(
        payload,
        const ChecksumSpec(mode: LegacyChecksumMode.add8, startByte: 1),
      );

      expect(result, orderedEquals(<int>[0x01, 0x02, 0x03, 0x06]));
      expect(payload, orderedEquals(<int>[0x01, 0x02, 0x03]));
    });

    test('按 1-based 起始位置选择参与校验的数据', () {
      final result = ChecksumInjector.apply(
        Uint8List.fromList(<int>[0x00, 0x01, 0x02, 0xAA, 0xBB]),
        const ChecksumSpec(
          mode: LegacyChecksumMode.add8,
          startByte: 2,
          trailingByteCount: 2,
        ),
      );

      expect(result, orderedEquals(<int>[0x00, 0x01, 0x02, 0x03, 0xAA, 0xBB]));
    });

    test('none 模式返回独立副本并忽略范围参数', () {
      final payload = Uint8List.fromList(<int>[0x01, 0x02]);
      final result = ChecksumInjector.apply(
        payload,
        const ChecksumSpec(
          mode: LegacyChecksumMode.none,
          startByte: 99,
          trailingByteCount: -1,
        ),
      );

      result[0] = 0xFF;
      expect(payload, orderedEquals(<int>[0x01, 0x02]));
    });

    test('空区间或越过边界时抛出结构化范围异常', () {
      final payload = Uint8List.fromList(<int>[0x01, 0x02, 0x03]);
      final invalidSpecs = <ChecksumSpec>[
        const ChecksumSpec(mode: LegacyChecksumMode.add8, startByte: 0),
        const ChecksumSpec(mode: LegacyChecksumMode.add8, startByte: 4),
        const ChecksumSpec(
          mode: LegacyChecksumMode.add8,
          startByte: 1,
          trailingByteCount: -1,
        ),
        const ChecksumSpec(
          mode: LegacyChecksumMode.add8,
          startByte: 1,
          trailingByteCount: 3,
        ),
        const ChecksumSpec(
          mode: LegacyChecksumMode.add8,
          startByte: 1,
          trailingByteCount: 4,
        ),
      ];

      for (final spec in invalidSpecs) {
        expect(
          () => ChecksumInjector.apply(payload, spec),
          throwsA(isA<ChecksumRangeException>()),
          reason:
              'startByte=${spec.startByte}, '
              'trailingByteCount=${spec.trailingByteCount}',
        );
      }
    });
  });
}
