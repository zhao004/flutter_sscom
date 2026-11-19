import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_sscom/features/terminal/application/terminal_projection.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TerminalProjection', () {
    test('总容量包含当前行且折行不会拆开 UTF-16 代理对', () {
      final projection = TerminalProjection(
        maxLines: 100,
        hexBytesPerLine: 16,
        maxTextLineCodeUnits: 5,
        maxTextCodeUnits: 9,
      );
      final now = DateTime(2026);
      for (var index = 0; index < 20; index++) {
        projection.append(Uint8List.fromList(utf8.encode('😀你')), now);
        final lines = projection.snapshot(TerminalDisplayMode.text);
        expect(
          lines.fold<int>(0, (sum, line) => sum + line.text.length),
          lessThanOrEqualTo(9),
        );
        for (final line in lines) {
          expect(line.text.length, lessThanOrEqualTo(5));
          expect(utf8.decode(utf8.encode(line.text)), line.text);
        }
      }
      expect(projection.droppedLines(TerminalDisplayMode.text), greaterThan(0));
      projection.clear();
      projection.append(Uint8List.fromList(utf8.encode('新\r\n行')), now);
      expect(
        projection.snapshot(TerminalDisplayMode.text).map((line) => line.text),
        ['新', '行'],
      );
      expect(projection.droppedLines(TerminalDisplayMode.text), 0);
    });

    test('持续无换行输入在 HEX 模式下仍受单行和总文本容量限制', () {
      final projection = TerminalProjection(maxLines: 10, hexBytesPerLine: 16);
      final batch = Uint8List.fromList(List<int>.filled(16384, 0x61));
      for (var index = 0; index < 40; index++) {
        projection.append(batch, DateTime(2026));
        projection.snapshot(TerminalDisplayMode.hex);
      }
      final lines = projection.snapshot(TerminalDisplayMode.text);
      expect(lines.every((line) => line.text.length <= 4096), isTrue);
      expect(
        lines.fold<int>(0, (sum, line) => sum + line.text.length),
        lessThanOrEqualTo(256 * 1024),
      );
      expect(projection.droppedLines(TerminalDisplayMode.text), greaterThan(0));
    });

    test('跨批次保留不完整 UTF-8 字节并正确合成多字节字符', () {
      final projection = TerminalProjection(maxLines: 10, hexBytesPerLine: 4);
      final bytes = Uint8List.fromList(utf8.encode('你'));
      final firstReceivedAt = DateTime(2026, 11, 12, 10, 0, 0);

      projection.append(Uint8List.fromList(<int>[bytes[0]]), firstReceivedAt);
      expect(projection.pendingUtf8Bytes, 1);
      expect(projection.snapshot(TerminalDisplayMode.text), isEmpty);

      projection.append(
        Uint8List.fromList(bytes.sublist(1)),
        firstReceivedAt.add(const Duration(milliseconds: 10)),
      );
      expect(projection.pendingUtf8Bytes, 0);
      final lines = projection.snapshot(TerminalDisplayMode.text);
      expect(lines, hasLength(1));
      expect(lines.single.text, '你');
      expect(lines.single.timestamp, firstReceivedAt);
    });

    test('统一处理 CRLF、CR 和 LF，并跨批抑制重复换行', () {
      final projection = TerminalProjection(maxLines: 10, hexBytesPerLine: 4);
      final now = DateTime(2026, 11, 12);

      projection.append(Uint8List.fromList(utf8.encode('a\r')), now);
      projection.append(
        Uint8List.fromList(utf8.encode('\nb\rc\n')),
        now.add(const Duration(milliseconds: 1)),
      );

      expect(
        projection.snapshot(TerminalDisplayMode.text).map((line) => line.text),
        <String>['a', 'b', 'c'],
      );
    });

    test('HEX 投影包含偏移、填充字节和 ASCII 预览', () {
      final projection = TerminalProjection(maxLines: 10, hexBytesPerLine: 4);
      projection.append(
        Uint8List.fromList(<int>[0x01, 0x02, 0x03, 0x41]),
        DateTime(2026, 11, 12),
      );

      final line = projection.snapshot(TerminalDisplayMode.hex).single;
      expect(line.text, '00000000  01 02 03 41  |...A|');
      expect(line.byteOffset, 0);
    });

    test('超过行数上限时保留最新行并累计裁剪数', () {
      final projection = TerminalProjection(maxLines: 2, hexBytesPerLine: 4);
      projection.append(
        Uint8List.fromList(utf8.encode('a\nb\nc\nd\n')),
        DateTime(2026, 11, 12),
      );

      final lines = projection.snapshot(TerminalDisplayMode.text);
      expect(lines.map((line) => line.text), <String>['c', 'd']);
      expect(projection.droppedLines(TerminalDisplayMode.text), 2);
    });

    test('部分行更新不会反复裁剪已提交历史', () {
      final projection = TerminalProjection(maxLines: 2, hexBytesPerLine: 4);
      projection.append(
        Uint8List.fromList(utf8.encode('a\nb\nc')),
        DateTime(2026, 11, 12),
      );

      expect(
        projection.snapshot(TerminalDisplayMode.text).map((line) => line.text),
        <String>['b', 'c'],
      );
      expect(projection.droppedLines(TerminalDisplayMode.text), 0);

      projection.append(
        Uint8List.fromList(utf8.encode('d')),
        DateTime(2026, 11, 12),
      );
      expect(
        projection.snapshot(TerminalDisplayMode.text).map((line) => line.text),
        <String>['b', 'cd'],
      );
      expect(projection.droppedLines(TerminalDisplayMode.text), 0);
    });

    test('非法 UTF-8 使用替换字符且清屏重置所有投影', () {
      final projection = TerminalProjection(maxLines: 4, hexBytesPerLine: 4);
      projection.append(
        Uint8List.fromList(<int>[0xFF]),
        DateTime(2026, 11, 12),
      );
      expect(
        projection.snapshot(TerminalDisplayMode.text).single.text,
        '\uFFFD',
      );

      projection.clear();
      expect(projection.snapshot(TerminalDisplayMode.text), isEmpty);
      expect(projection.snapshot(TerminalDisplayMode.hex), isEmpty);
      expect(projection.pendingUtf8Bytes, 0);
      expect(projection.droppedLines(TerminalDisplayMode.text), 0);
    });
  });
}
