import 'dart:convert';
import 'dart:io';

import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/settings/infrastructure/legacy_ini_migrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrator = LegacyIniMigrator();
  final root = Directory('test/fixtures/legacy');
  final iniRoot = Directory('${root.path}/sscom51_compat');

  group('LegacyIniMigrator', () {
    test('正常快照迁移串口、发送、多字符串且无警告', () {
      final result = migrator.migrate(
        File('${iniRoot.path}/valid_default.ini').readAsBytesSync(),
        sourceName: 'valid_default.ini',
        migratedAtUtc: DateTime.utc(2026, 11, 12),
      );

      expect(result.warnings, isEmpty);
      expect(result.settings.serial.portName, 'COM99');
      expect(result.settings.serial.baudRate, 115200);
      expect(result.settings.serial.initialDtr, isTrue);
      expect(result.settings.serial.initialRts, isFalse);
      expect(result.settings.send.mode, SendInputMode.ansiText);
      expect(result.settings.send.textDraft, contains(','));
      expect(result.settings.send.textDraft, contains('redacted'));
      expect(result.settings.send.appendCrLf, isTrue);
      expect(result.settings.send.checksumMode, LegacyChecksumMode.none);
      expect(result.settings.multiSend, hasLength(99));
      expect(result.settings.multiSend.first.index, 1);
      expect(result.settings.multiSend.first.mode, SendInputMode.hex);
      expect(result.settings.multiSend.first.payload, '13 00 FF 88');
      expect(result.settings.multiSend.first.enabled, isTrue);
      expect(result.settings.network.safetyMode, NetworkSafetyMode.safe);
      expect(result.settings.network.bindAddress, '127.0.0.1');
      expect(result.settings.network.followRemoteEndpoint, isTrue);
      expect(result.settings.migration?.warnings, isEmpty);
    });

    test('异常、重复、未知、NUL 和无末尾换行均产生稳定警告', () {
      final manifest = jsonDecode(
        File('${root.path}/legacy_ini_cases.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final cases = (manifest['cases'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

      for (final item in cases) {
        final file = File('${iniRoot.path}/${item['file']}');
        final result = migrator.migrate(
          file.readAsBytesSync(),
          sourceName: item['file'] as String,
          migratedAtUtc: DateTime.utc(2026, 11, 12),
        );
        final actual = result.warnings
            .map((warning) => warning.code.id)
            .toSet();
        for (final expected in (item['expectedWarnings'] as List<dynamic>)) {
          expect(actual, contains(expected), reason: item['id'] as String);
        }
      }
    });

    test('N1053 与 N1054 的 0x02/0x03/0x04 存储转义恢复为逗号与换行', () {
      final result = migrator.migrate(
        File('${iniRoot.path}/escaped_payload.ini').readAsBytesSync(),
        sourceName: 'escaped_payload.ini',
      );

      expect(result.settings.send.textDraft, contains(','));
      expect(result.settings.send.textDraft, contains('\r\n'));
      expect(result.settings.send.hexDraft, contains('\r\n'));
    });
  });
}
