import 'dart:convert';
import 'dart:io';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:flutter_sscom/features/settings/infrastructure/json_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JsonSettingsRepository', () {
    late Directory directory;
    late File settingsFile;

    setUp(() async {
      directory = Directory(
        '.cache/test-settings/${DateTime.now().microsecondsSinceEpoch}',
      );
      await directory.create(recursive: true);
      settingsFile = File('${directory.path}/settings.json');
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('保存后可重新加载并保留旧文件备份', () async {
      final repository = JsonSettingsRepository(settingsFile);
      final first = AppSettings(
        serial: const SerialConfig(portName: 'COM1', baudRate: 9600),
      );
      await repository.save(first);
      expect(await settingsFile.exists(), isTrue);
      expect(await repository.temporaryFile.exists(), isFalse);

      final second = first.copyWith(
        serial: const SerialConfig(portName: 'COM2', baudRate: 115200),
      );
      await repository.save(second);
      expect(await repository.backupFile.exists(), isTrue);

      final restored = await repository.load();
      expect(restored?.serial.portName, 'COM2');
      expect(restored?.serial.baudRate, 115200);
    });

    test('主文件缺失时从最近备份恢复', () async {
      final repository = JsonSettingsRepository(settingsFile);
      await repository.save(
        AppSettings(
          serial: const SerialConfig(portName: 'COM1', baudRate: 9600),
        ),
      );
      await repository.save(
        AppSettings(
          serial: const SerialConfig(portName: 'COM2', baudRate: 19200),
        ),
      );
      await settingsFile.delete();

      final restored = await repository.load();

      expect(await settingsFile.exists(), isTrue);
      expect(restored?.serial.portName, 'COM1');
    });

    test('损坏 JSON 抛出结构化仓库异常', () async {
      await settingsFile.writeAsString('{broken', encoding: utf8);
      final repository = JsonSettingsRepository(settingsFile);

      await expectLater(
        repository.load(),
        throwsA(isA<SettingsRepositoryException>()),
      );
    });
  });
}
