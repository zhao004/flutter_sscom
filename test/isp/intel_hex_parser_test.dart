import 'package:flutter_sscom/core/isp/intel_hex_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IntelHexParser', () {
    test('合并 1 MiB 连续短记录并保留乱序输入中的间隙', () {
      final source = StringBuffer();
      for (var page = 0; page < 16; page++) {
        source.writeln(_record(0, 4, [0x08, page]));
        // 每个地址页中的记录逆序，合并必须以地址排序结果为准。
        for (var offset = 65520; offset >= 0; offset -= 16) {
          source.writeln(
            _record(
              offset,
              0,
              List<int>.generate(16, (index) => (offset + index) & 255),
            ),
          );
        }
      }
      source.writeln(_record(0, 4, [0x08, 0x11]));
      source.writeln(_record(0, 0, [0xAA]));
      source.writeln(_eof());
      final image = parseIntelHex(source.toString());
      expect(image.segmentCount, 2);
      expect(image.segments.first.bytes.length, 1024 * 1024);
      expect(
        image.segments.first.bytes,
        orderedEquals(List<int>.generate(1024 * 1024, (index) => index & 255)),
      );
      expect(image.segments.last.startAddress, 0x08110000);
      expect(image.segments.last.bytes, [0xAA]);
    });

    test('解析扩展线性地址、连续记录和起始线性地址', () {
      final source = <String>[
        _record(0x0000, 0x04, <int>[0x00, 0x01]),
        _record(0x0010, 0x00, <int>[0x01, 0x02]),
        _record(0x0012, 0x00, <int>[0x03]),
        _record(0x0000, 0x05, <int>[0x00, 0x01, 0x00, 0x10]),
        _record(0x0000, 0x01, const <int>[]),
      ].join('\r\n');

      final image = parseIntelHex(source);

      expect(image.segmentCount, 1);
      expect(image.minimumAddress, 0x10010);
      expect(image.maximumAddressExclusive, 0x10013);
      expect(image.totalBytes, 3);
      expect(image.segments.single.bytes, orderedEquals(<int>[1, 2, 3]));
      expect(image.entryPoint, 0x10010);
    });

    test('解析扩展段地址', () {
      final source = <String>[
        _record(0x0000, 0x02, <int>[0x12, 0x34]),
        _record(0x0056, 0x00, <int>[0xAA]),
        _record(0x0000, 0x01, const <int>[]),
      ].join('\n');

      final image = parseIntelHex(source);

      expect(image.minimumAddress, 0x12340 + 0x56);
      expect(image.segments.single.bytes, orderedEquals(<int>[0xAA]));
    });

    test('拒绝错误 checksum、截断记录和未知记录类型', () {
      final valid = _record(0, 0, <int>[1, 2]);
      final badChecksum = '${valid.substring(0, valid.length - 2)}00';
      expect(
        () => parseIntelHex('$badChecksum\n${_eof()}'),
        throwsA(isA<IntelHexFormatException>()),
      );
      expect(
        () => parseIntelHex(':020000000102\n${_eof()}'),
        throwsA(isA<IntelHexFormatException>()),
      );
      expect(
        () => parseIntelHex('${_record(0, 0x7A, const <int>[])}\n${_eof()}'),
        throwsA(isA<IntelHexFormatException>()),
      );
    });

    test('拒绝重叠数据和缺失 EOF', () {
      expect(
        () => parseIntelHex(
          <String>[
            _record(0x0010, 0x00, <int>[1, 2]),
            _record(0x0011, 0x00, <int>[3]),
            _eof(),
          ].join('\n'),
        ),
        throwsA(isA<IntelHexFormatException>()),
      );
      expect(
        () => parseIntelHex(_record(0, 0, <int>[1])),
        throwsA(isA<IntelHexFormatException>()),
      );
    });

    test('拒绝 EOF 后数据、地址上界溢出和冲突入口', () {
      expect(
        () => parseIntelHex(
          <String>[
            _record(0, 0, <int>[1]),
            _eof(),
            _record(0, 0, <int>[2]),
          ].join('\n'),
        ),
        throwsA(isA<IntelHexFormatException>()),
      );
      expect(
        () => parseIntelHex(
          <String>[
            _record(0, 0x04, <int>[0xFF, 0xFF]),
            _record(0xFFFF, 0x00, <int>[1, 2]),
            _eof(),
          ].join('\n'),
        ),
        throwsA(isA<IntelHexFormatException>()),
      );
      expect(
        () => parseIntelHex(
          <String>[
            _record(0, 0x05, <int>[0, 0, 0, 1]),
            _record(0, 0x05, <int>[0, 0, 0, 2]),
            _record(0, 0, <int>[1]),
            _eof(),
          ].join('\n'),
        ),
        throwsA(isA<IntelHexFormatException>()),
      );
    });
  });
}

String _eof() => _record(0, 0x01, const <int>[]);

String _record(int address, int type, List<int> data) {
  final bytes = <int>[
    data.length,
    (address >> 8) & 0xFF,
    address & 0xFF,
    type,
    ...data,
  ];
  var sum = bytes.fold<int>(0, (total, byte) => (total + byte) & 0xFF);
  bytes.add((0x100 - sum) & 0xFF);
  return ':${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase()).join()}';
}
