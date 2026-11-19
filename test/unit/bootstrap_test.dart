import 'dart:io';

import 'package:flutter_sscom/app/bootstrap.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/multi_send/application/multi_send_controller.dart';
import 'package:flutter_sscom/features/isp/application/isp_controller.dart';
import 'package:flutter_sscom/features/settings/application/settings_migration_controller.dart';
import 'package:flutter_sscom/features/settings/application/settings_persistence_coordinator.dart';
import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_sscom/features/waveform/application/waveform_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../support/fake_serial_transport.dart';
import '../support/in_memory_settings_repository.dart';

void main() {
  test('bootstrap 使用隔离容器注册并释放长期依赖', () async {
    final container = GetIt.asNewInstance();

    final dependencies = await bootstrap(
      serialTransport: FakeSerialTransport(),
      serviceLocator: container,
    );

    expect(container.isRegistered<GoRouter>(), isTrue);
    expect(container.isRegistered<SerialTransport>(), isTrue);
    expect(container.isRegistered<TerminalController>(), isTrue);
    expect(container.isRegistered<MultiSendController>(), isTrue);
    expect(container.isRegistered<WaveformController>(), isTrue);
    expect(container.isRegistered<IspController>(), isTrue);
    expect(dependencies.router, same(container<GoRouter>()));
    await dependencies.shutdown();
    await container.reset();
    expect(container.isRegistered<GoRouter>(), isFalse);
    expect(container.isRegistered<TerminalController>(), isFalse);
  });

  test('bootstrap 注册设置协调器并在 shutdown 时刷新偏好', () async {
    final container = GetIt.asNewInstance();
    final repository = InMemorySettingsRepository();
    final settings = AppSettings.defaults();

    final dependencies = await bootstrap(
      serialTransport: FakeSerialTransport(),
      serviceLocator: container,
      settingsRepository: repository,
      settingsBackupDirectory: Directory('.cache/test-bootstrap-migration'),
      settings: settings,
    );
    final controller = container<TerminalController>();

    expect(container.isRegistered<SettingsPersistenceCoordinator>(), isTrue);
    expect(container.isRegistered<SettingsMigrationController>(), isTrue);
    controller.setShowTimestamp(true);
    await dependencies.shutdown();

    expect(repository.saveCount, 1);
    expect(repository.settings?.terminal.showTimestamp, isTrue);
    await container.reset();
  });

  test('设置保存失败时 shutdown 仍释放传输资源', () async {
    final container = GetIt.asNewInstance();
    final transport = FakeSerialTransport();
    final repository = InMemorySettingsRepository()
      ..saveError = StateError('模拟磁盘写入失败');

    final dependencies = await bootstrap(
      serviceLocator: container,
      serialTransport: transport,
      settingsRepository: repository,
      settings: AppSettings.defaults(),
    );
    final controller = container<TerminalController>();
    controller.setShowTimestamp(true);

    await dependencies.shutdown();

    expect(transport.isDisposed, isTrue);
    await container.reset();
  });
}
