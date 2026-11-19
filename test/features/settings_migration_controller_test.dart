import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/settings/application/settings_migration_controller.dart';
import 'package:flutter_sscom/features/settings/application/settings_persistence_coordinator.dart';
import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_serial_transport.dart';
import '../support/in_memory_settings_repository.dart';

void main() {
  group('SettingsMigrationController', () {
    late Directory directory;

    setUp(() async {
      directory = Directory(
        '.cache/test-settings-migration/${DateTime.now().microsecondsSinceEpoch}',
      );
      await directory.create(recursive: true);
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('预览后备份原始 INI、保存迁移设置并暂停旧会话覆盖', () async {
      final source = File(
        'test/fixtures/legacy/sscom51_compat/minimal_missing.ini',
      );
      final sourceBefore = await source.readAsBytes();
      final transport = FakeSerialTransport();
      final terminal = TerminalController(
        transport: transport,
        textEncoder: const Utf8TextByteEncoder(),
        backendLabel: '测试串口',
      );
      final repository = InMemorySettingsRepository(
        settings: AppSettings.defaults(),
      );
      final coordinator = SettingsPersistenceCoordinator(
        repository: repository,
        controller: terminal,
        initialSettings: AppSettings.defaults(),
        debounce: const Duration(milliseconds: 10),
      );
      final migration = SettingsMigrationController(
        coordinator: coordinator,
        backupDirectory: Directory('${directory.path}/backup'),
        now: () => DateTime.utc(2026, 11, 13, 12),
      );

      try {
        await migration.inspectFile(source);

        expect(migration.state.value.phase, SettingsMigrationPhase.preview);
        expect(migration.state.value.result, isNotNull);
        expect(migration.state.value.result?.warnings, isNotEmpty);
        expect(repository.saveCount, 0);

        await migration.apply();

        expect(migration.state.value.phase, SettingsMigrationPhase.completed);
        expect(coordinator.isSuspended, isTrue);
        expect(repository.saveCount, 1);
        expect(
          repository.settings?.migration?.sourceName,
          'minimal_missing.ini',
        );
        final backupPath = migration.state.value.backupPath;
        expect(backupPath, isNotNull);
        final backup = File(backupPath!);
        expect(await backup.exists(), isTrue);
        expect(await backup.readAsBytes(), orderedEquals(sourceBefore));
        expect(await source.readAsBytes(), orderedEquals(sourceBefore));

        terminal.updateSendDraft('迁移后不应覆盖');
        await coordinator.dispose();
        expect(repository.settings?.send.textDraft, isNot('迁移后不应覆盖'));
      } finally {
        await migration.dispose();
        await coordinator.dispose();
        await terminal.dispose();
      }
    });

    test('活动串口连接存在时拒绝创建备份和保存', () async {
      final transport = FakeSerialTransport(
        initialPorts: const <SerialPortInfo>[
          SerialPortInfo(
            systemPath: 'COM1',
            displayName: 'COM1',
            isAvailable: true,
          ),
        ],
      );
      final terminal = TerminalController(
        transport: transport,
        textEncoder: const Utf8TextByteEncoder(),
        backendLabel: '测试串口',
        initialConfig: const SerialConfig(portName: 'COM1', baudRate: 115200),
      );
      final repository = InMemorySettingsRepository();
      final coordinator = SettingsPersistenceCoordinator(
        repository: repository,
        controller: terminal,
        initialSettings: AppSettings.defaults(),
      );
      final backupDirectory = Directory('${directory.path}/backup');
      final migration = SettingsMigrationController(
        coordinator: coordinator,
        backupDirectory: backupDirectory,
        fileReader: (_) async =>
            Uint8List.fromList('N1080=,COM99\nN1081=,115200\n'.codeUnits),
      );

      try {
        await terminal.initialize();
        await terminal.open();
        await migration.inspectFile(File('sscom51.ini'));
        await migration.apply();

        expect(migration.state.value.phase, SettingsMigrationPhase.failed);
        expect(migration.state.value.errorMessage, contains('断开'));
        expect(repository.saveCount, 0);
        expect(await backupDirectory.exists(), isFalse);
      } finally {
        await migration.dispose();
        await coordinator.dispose();
        await terminal.dispose();
      }
    });

    test('保存失败后恢复自动保存并允许重试', () async {
      final terminal = TerminalController(
        transport: FakeSerialTransport(),
        textEncoder: const Utf8TextByteEncoder(),
        backendLabel: '测试串口',
      );
      final repository = InMemorySettingsRepository(
        settings: AppSettings.defaults(),
      )..saveError = StateError('模拟保存失败');
      final coordinator = SettingsPersistenceCoordinator(
        repository: repository,
        controller: terminal,
        initialSettings: AppSettings.defaults(),
      );
      final backupDirectory = Directory('${directory.path}/backup');
      final migration = SettingsMigrationController(
        coordinator: coordinator,
        backupDirectory: backupDirectory,
        fileReader: (_) async =>
            Uint8List.fromList('N1080=,COM99\nN1081=,115200\n'.codeUnits),
        now: () => DateTime.utc(2026, 11, 13, 13),
      );

      try {
        await migration.inspectFile(File('sscom51.ini'));
        await migration.apply();

        expect(migration.state.value.phase, SettingsMigrationPhase.failed);
        expect(migration.state.value.errorMessage, contains('模拟保存失败'));
        expect(coordinator.isSuspended, isFalse);
        expect(repository.saveCount, 1);
        final firstBackup = File(
          '${backupDirectory.path}/sscom51.ini.2026-11-13T13-00-00-000Z.bak',
        );
        expect(await firstBackup.exists(), isTrue);

        repository.saveError = null;
        await migration.apply();

        expect(migration.state.value.phase, SettingsMigrationPhase.completed);
        expect(coordinator.isSuspended, isTrue);
        expect(repository.saveCount, 2);
        expect(repository.settings?.serial.portName, 'COM99');
      } finally {
        await migration.dispose();
        await coordinator.dispose();
        await terminal.dispose();
      }
    });

    test('注入读取器返回超限内容时拒绝预览', () async {
      final terminal = TerminalController(
        transport: FakeSerialTransport(),
        textEncoder: const Utf8TextByteEncoder(),
        backendLabel: '测试串口',
      );
      final coordinator = SettingsPersistenceCoordinator(
        repository: InMemorySettingsRepository(),
        controller: terminal,
        initialSettings: AppSettings.defaults(),
      );
      final migration = SettingsMigrationController(
        coordinator: coordinator,
        backupDirectory: Directory('${directory.path}/backup'),
        maxSourceBytes: 4,
        fileReader: (_) async => Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
      );

      try {
        await migration.inspectFile(File('sscom51.ini'));

        expect(migration.state.value.phase, SettingsMigrationPhase.failed);
        expect(migration.state.value.result, isNull);
        expect(migration.state.value.errorMessage, contains('大小上限'));
      } finally {
        await migration.dispose();
        await coordinator.dispose();
        await terminal.dispose();
      }
    });
  });
}
