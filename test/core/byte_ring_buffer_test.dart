import 'dart:typed_data';

import 'package:flutter_sscom/core/buffers/buffers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ByteRingBuffer', () {
    test('拒绝非正容量', () {
      expect(() => ByteRingBuffer(0), throwsArgumentError);
      expect(() => ByteRingBuffer(-1), throwsArgumentError);
    });

    test('零长度追加不改变状态', () {
      final buffer = ByteRingBuffer(4)..append(_bytes(<int>[1, 2]));

      expect(buffer.append(Uint8List(0)), 0);
      expect(buffer.length, 2);
      expect(buffer.discardedBytes, 0);
      expect(buffer.snapshot(), orderedEquals(<int>[1, 2]));
    });

    test('恰好填满容量时保留完整数据', () {
      final buffer = ByteRingBuffer(4);

      expect(buffer.append(_bytes(<int>[1, 2, 3, 4])), 0);
      expect(buffer.length, 4);
      expect(buffer.discardedBytes, 0);
      expect(buffer.snapshot(), orderedEquals(<int>[1, 2, 3, 4]));
    });

    test('跨越底层数组边界时仍按到达顺序读取', () {
      final buffer = ByteRingBuffer(5)
        ..append(_bytes(<int>[1, 2, 3]))
        ..append(_bytes(<int>[4, 5, 6, 7]));

      expect(buffer.length, 5);
      expect(buffer.discardedBytes, 2);
      expect(buffer.snapshot(), orderedEquals(<int>[3, 4, 5, 6, 7]));
    });

    test('单批超过容量时只保留最新尾部并累计丢弃数', () {
      final buffer = ByteRingBuffer(4)..append(_bytes(<int>[1, 2]));
      final dropped = buffer.append(_bytes(<int>[3, 4, 5, 6, 7]));

      expect(dropped, 3);
      expect(buffer.length, 4);
      expect(buffer.discardedBytes, 3);
      expect(buffer.snapshot(), orderedEquals(<int>[4, 5, 6, 7]));

      expect(buffer.append(_bytes(<int>[8, 9, 10, 11, 12])), 5);
      expect(buffer.discardedBytes, 8);
      expect(buffer.snapshot(), orderedEquals(<int>[9, 10, 11, 12]));
    });

    test('快照与内部存储隔离，清空保留累计丢弃数', () {
      final buffer = ByteRingBuffer(4)..append(_bytes(<int>[1, 2]));
      final snapshot = buffer.snapshot();
      snapshot[0] = 9;

      expect(buffer.snapshot(), orderedEquals(<int>[1, 2]));
      expect(buffer.append(_bytes(<int>[3, 4, 5])), 1);
      buffer.clear();
      expect(buffer.length, 0);
      expect(buffer.isEmpty, isTrue);
      expect(buffer.snapshot(), isEmpty);
      expect(buffer.discardedBytes, 1);
    });
  });
}

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);
