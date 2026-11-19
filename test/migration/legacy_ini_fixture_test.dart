import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _fixtureRoot = Directory('test/fixtures/legacy');
final _iniRoot = Directory('${_fixtureRoot.path}/sscom51_compat');

Map<String, dynamic> _loadJson(String name) {
  final file = File('${_fixtureRoot.path}/$name');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

List<int> _read(String name) =>
    File('${_iniRoot.path}/$name').readAsBytesSync();

void _expectCrlfFile(List<int> bytes) {
  expect(
    List<int>.generate(
      bytes.length - 1,
      (index) => index,
    ).any((index) => bytes[index] == 0x0D && bytes[index + 1] == 0x0A),
    isTrue,
  );
}

void _expectNoBom(List<int> bytes) {
  final hasBom =
      bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF;
  expect(hasBom, isFalse);
}

void main() {
  group('SSCOM INI 夹具', () {
    test('清单中的所有文件存在且编码边界符合预期', () {
      final manifest = _loadJson('legacy_ini_cases.json');
      final cases = (manifest['cases'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      expect(cases, isNotEmpty);
      for (final item in cases) {
        final bytes = _read(item['file'] as String);
        expect(bytes, isNotEmpty, reason: item['file'] as String);
        _expectCrlfFile(bytes);
        _expectNoBom(bytes);
      }
    });

    test('完整脱敏快照覆盖关键配置且不包含真实命令片段', () {
      final bytes = _read('valid_default.ini');
      final text = latin1.decode(bytes);
      final requiredKeys = <String>[
        'N1=',
        'N101=1,',
        'N1051=,',
        'N1053=,',
        'N1060=,',
        'N1067=,',
        'N1074=,',
        'N1075=,',
        'N1080=,',
        'N1081=,',
        'N1100=,',
      ];

      for (final key in requiredKeys) {
        expect(text.contains(key), isTrue, reason: key);
      }
      expect(text.contains('AT+DEMO="fixture"'), isTrue);
      expect(text.contains('"redacted"'), isTrue);
      expect(bytes.contains(0x02), isTrue);
      expect(bytes.contains(0x00), isFalse);
      expect(text.contains('N1080=,COM99'), isTrue);
    });

    test('异常夹具保留缺失、非法、重复、未知和尾部边界', () {
      final invalidText = latin1.decode(_read('invalid_values.ini'));
      expect(invalidText.contains('N1060=,9'), isTrue);
      expect(invalidText.contains('N1067=,123'), isTrue);
      expect(invalidText.contains('N1074=,0'), isTrue);
      expect(invalidText.contains('N1075=,-1'), isTrue);
      expect(invalidText.contains('N1081=,not-a-baud'), isTrue);

      final duplicateText = latin1.decode(_read('duplicate_unknown.ini'));
      expect(
        RegExp(r'^N1060=', multiLine: true).allMatches(duplicateText),
        hasLength(2),
      );
      expect(duplicateText.contains('N9999=,unknown-value'), isTrue);

      expect(_read('nul_value.ini').contains(0x00), isTrue);

      final noFinalNewline = _read('no_final_newline.ini');
      expect(noFinalNewline.length, greaterThanOrEqualTo(2));
      expect(
        noFinalNewline.sublist(noFinalNewline.length - 2),
        isNot(<int>[0x0D, 0x0A]),
      );
    });

    test('N1053 存储转义保留逗号、CR 和 LF 的控制字节', () {
      final bytes = _read('escaped_payload.ini');
      expect(bytes.contains(0x02), isTrue);
      expect(bytes.contains(0x03), isTrue);
      expect(bytes.contains(0x04), isTrue);
    });

    test('配置键说明覆盖校验、窗口和串口字段', () {
      final data = _loadJson('config_keys.json');
      final entries = (data['entries'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((entry) => entry['key'] ?? entry['pattern'])
          .toSet();

      for (final key in <String>[
        'N1053',
        'N1060',
        'N1067',
        'N1074',
        'N1075',
        'N1080',
        'N1081',
        'N1082..N1087',
        'N1100',
      ]) {
        expect(entries.contains(key), isTrue, reason: key);
      }
    });
  });
}
