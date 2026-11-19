import 'dart:io';

import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:flutter_sscom/features/settings/infrastructure/settings_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/in_memory_settings_repository.dart';

void main() {
  group('SettingsBootstrapService', () {
    late Directory directory;

    setUp(() async {
      directory = Directory(
        '.cache/test-settings-bootstrap/${DateTime.now().microsecondsSinceEpoch}',
      );
      await directory.create(recursive: true);
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('首次启动迁移旧 INI、备份原文件并保存 JSON 设置', () async {
      final legacyFile = File('${directory.path}/sscom51.ini');
      await File('test/fixtures/legacy/sscom51_compat/valid_default.ini')
          .copy(legacyFile.path);
      final repository = InMemorySettingsRepository();
      final backupDirectory = Directory('${directory.path}/migration-backup');
      final service = SettingsBootstrapService(
        repository: repository,
        backupDirectory: backupDirectory,
        legacyIniLocator: LegacyIniLocator(<Directory>[directory]),
      );

      final result = await service.loadOrMigrate();

      expect(result.persistenceEnabled, isTrue);
      expect(result.settings.serial.portName, 'COM99');
      expect(repository.settings, isNotNull);
      expect(await legacyFile.exists(), isTrue);
      final backups = await backupDirectory
          .list()
          .where((entity) => entity is File)
          .toList();
      expect(backups, hasLength(1));
      expect(result.notices.any((notice) => notice.contains('迁移')), isTrue);
    });

    test('已有 settings.json 时跳过旧 INI 迁移', () async {
      final legacyFile = File('${directory.path}/sscom51.ini');
      await File('test/fixtures/legacy/sscom51_compat/valid_default.ini')
          .copy(legacyFile.path);
      final repository = InMemorySettingsRepository(
        settings: AppSettings.defaults().copyWith(locale: 'en-US'),
      );
      final service = SettingsBootstrapService(
        repository: repository,
        backupDirectory: Directory('${directory.path}/migration-backup'),
        legacyIniLocator: LegacyIniLocator(<Directory>[directory]),
      );

      final result = await service.loadOrMigrate();

      expect(result.settings.locale, 'en-US');
      expect(repository.loadCount, 1);
      expect(repository.saveCount, 0);
    });

    test('备份目录不可创建时使用迁移结果但禁用持久化', () async {
      final legacyFile = File('${directory.path}/sscom51.ini');
      await File('test/fixtures/legacy/sscom51_compat/valid_default.ini')
          .copy(legacyFile.path);
      final blockedBackup = File('${directory.path}/migration-backup');
      await blockedBackup.writeAsString('not a directory');
      final repository = InMemorySettingsRepository();
      final service = SettingsBootstrapService(
        repository: repository,
        backupDirectory: Directory(blockedBackup.path),
        legacyIniLocator: LegacyIniLocator(<Directory>[directory]),
      );

      final result = await service.loadOrMigrate();

      expect(result.persistenceEnabled, isFalse);
      expect(result.settings.serial.portName, 'COM99');
      expect(repository.settings, isNull);
      expect(result.notices.any((notice) => notice.contains('备份失败')), isTrue);
    });
  });

  test('Windows 设置目录使用 APPDATA 下的 SSCOM', () async {
    final appDataDirectory = Directory(
      '.cache/test-settings-app-data/${DateTime.now().microsecondsSinceEpoch}',
    );
    addTearDown(() async {
      if (await appDataDirectory.exists()) {
        await appDataDirectory.delete(recursive: true);
      }
    });

    final directory = await resolveSettingsDirectory(
      isWindows: true,
      windowsAppDataPath: appDataDirectory.path,
      supportDirectoryProvider: () async => throw StateError('不应使用回退目录'),
    );

    expect(
      directory.path,
      '${appDataDirectory.path}${Platform.pathSeparator}SSCOM',
    );
  });
}
