import 'dart:async';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../core/buffers/buffers.dart';
import '../core/protocols/protocols.dart';
import '../core/transport/transport_barrel.dart';
import '../features/connection/infrastructure/io_network_transport_factory.dart';
import '../features/connection/infrastructure/serial_backend_factory.dart';
import '../features/file_transfer/application/file_send_controller.dart';
import '../features/file_transfer/application/receive_log_controller.dart';
import '../features/isp/application/isp_controller.dart';
import '../features/isp/presentation/isp_page.dart';
import '../features/multi_send/application/multi_send_controller.dart';
import '../features/settings/application/settings_migration_controller.dart';
import '../features/settings/application/settings_persistence_coordinator.dart';
import '../features/settings/domain/app_settings.dart';
import '../features/settings/presentation/settings_migration_page.dart';
import '../features/settings/infrastructure/json_settings_repository.dart';
import '../features/support/infrastructure/release_manifest_loader.dart';
import '../features/terminal/application/terminal_controller.dart';
import '../features/waveform/application/waveform_controller.dart';
import 'app.dart';
import 'router/app_router.dart';

/// 初始化应用依赖并返回可供根组件消费的组合结果。
///
/// 生产启动使用全局 GetIt；测试可传入独立容器、设置仓库和 [SerialTransport]
/// 覆盖，确保测试之间不共享状态或访问真实硬件。
Future<AppDependencies> bootstrap({
  GetIt? serviceLocator,
  SerialTransport? serialTransport,
  TransportFactory? networkTransportFactory,
  SettingsRepository? settingsRepository,
  Directory? settingsBackupDirectory,
  AppSettings? settings,
  String? initialNotice,
  IspFirmwareSelectionCallback? pickIspFirmware,
  IspFirmwareBytesReader? ispFirmwareReader,
  LegacyIniBytesReader? legacyIniReader,
  LegacyIniSelectionCallback? pickLegacyIni,
  AppReleaseInfoLoader? supportReleaseInfoLoader,
}) async {
  final container = serviceLocator ?? GetIt.instance;
  final appSettings = settings ?? AppSettings.defaults();
  final backend = serialTransport == null
      ? createSerialBackendFromEnvironment()
      : SerialBackendSelection(
          transport: serialTransport,
          label: '测试串口后端',
          isSimulated: false,
        );

  final controller = _registerDependencies(
    container,
    backend: backend,
    settings: appSettings,
    settingsRepository: settingsRepository,
    settingsBackupDirectory: settingsBackupDirectory,
    initialNotice: initialNotice,
    networkTransportFactory: networkTransportFactory,
    pickIspFirmware: pickIspFirmware,
    ispFirmwareReader: ispFirmwareReader,
    legacyIniReader: legacyIniReader,
    pickLegacyIni: pickLegacyIni,
    supportReleaseInfoLoader: supportReleaseInfoLoader,
  );
  await controller.initialize();
  Future<void>? shutdownFuture;
  return AppDependencies(
    router: container<GoRouter>(),
    shutdown: () => shutdownFuture ??= _shutdownDependencies(
      container: container,
      controller: controller,
    ),
  );
}

Future<void> _shutdownDependencies({
  required GetIt container,
  required TerminalController controller,
}) async {
  Future<void> disposeSafely(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // 关闭流程必须继续释放后续资源；具体错误已由各控制器暴露。
    }
  }

  // 先中止活动传输，解除 flush 等待，再回收依赖终端状态的发送任务。
  // ISP 会话需要先释放独占权，终端状态信号则保留到所有控制器退出之后。
  await disposeSafely(() async {
    if (container.isRegistered<IspController>()) {
      await container<IspController>().dispose();
    }
  });
  await disposeSafely(controller.close);
  await disposeSafely(() async {
    if (container.isRegistered<MultiSendController>()) {
      await container<MultiSendController>().dispose();
    }
  });
  await disposeSafely(() async {
    if (container.isRegistered<FileSendController>()) {
      await container<FileSendController>().dispose();
    }
  });
  await disposeSafely(() async {
    if (container.isRegistered<ReceiveLogController>()) {
      await container<ReceiveLogController>().dispose();
    }
  });
  await disposeSafely(() async {
    if (container.isRegistered<WaveformController>()) {
      await container<WaveformController>().dispose();
    }
  });
  await disposeSafely(() async {
    if (container.isRegistered<SettingsMigrationController>()) {
      await container<SettingsMigrationController>().dispose();
    }
  });
  await disposeSafely(() async {
    if (container.isRegistered<SettingsPersistenceCoordinator>()) {
      await container<SettingsPersistenceCoordinator>().dispose();
    }
  });
  await controller.dispose();
}

TerminalController _registerDependencies(
  GetIt container, {
  required SerialBackendSelection backend,
  required AppSettings settings,
  required SettingsRepository? settingsRepository,
  required Directory? settingsBackupDirectory,
  required String? initialNotice,
  required TransportFactory? networkTransportFactory,
  required IspFirmwareSelectionCallback? pickIspFirmware,
  required IspFirmwareBytesReader? ispFirmwareReader,
  required LegacyIniBytesReader? legacyIniReader,
  required LegacyIniSelectionCallback? pickLegacyIni,
  required AppReleaseInfoLoader? supportReleaseInfoLoader,
}) {
  final controller = TerminalController(
    transport: backend.transport,
    textEncoder: const Utf8TextByteEncoder(),
    backendLabel: backend.label,
    isSimulatedBackend: backend.isSimulated,
    networkTransportFactory:
        networkTransportFactory ?? const IoNetworkTransportFactory(),
    bufferPolicy: BufferPolicy(maxRawBytes: settings.terminal.maxRawBytes),
    initialConfig: settings.serial,
    initialTransportMode: settings.network.mode,
    initialNetworkSafetyMode: settings.network.safetyMode,
    initialRemoteHost: settings.network.remoteHost,
    initialRemotePort: settings.network.remotePort,
    initialBindAddress: settings.network.bindAddress,
    initialLocalPort: settings.network.localPort,
    initialFollowRemoteEndpoint: settings.network.followRemoteEndpoint,
    initialDisplayMode: settings.terminal.displayMode,
    initialShowTimestamp: settings.terminal.showTimestamp,
    initialAutoScroll: settings.terminal.autoScroll,
    initialSendMode: settings.send.mode,
    initialSendChecksumMode: settings.send.checksumMode,
    initialSendChecksumStartByte: settings.send.checksumStartByte,
    initialSendChecksumTrailingByteCount:
        settings.send.checksumTrailingByteCount,
    initialSendAppendCrLf: settings.send.appendCrLf,
    initialTextDraft: settings.send.textDraft,
    initialHexDraft: settings.send.hexDraft,
    initialNotice: initialNotice,
  );

  container.registerSingleton<SerialTransport>(backend.transport);
  container.registerSingleton<TerminalController>(
    controller,
    dispose: (controller) => controller.dispose(),
  );
  final multiSendController = MultiSendController(
    terminal: controller,
    initialEntries: settings.multiSend,
  );
  container.registerSingleton<MultiSendController>(
    multiSendController,
    dispose: (controller) => controller.dispose(),
  );
  SettingsPersistenceCoordinator? persistenceCoordinator;
  if (settingsRepository != null) {
    persistenceCoordinator = SettingsPersistenceCoordinator(
      repository: settingsRepository,
      controller: controller,
      multiSendController: multiSendController,
      initialSettings: settings,
    );
    container.registerSingleton<SettingsPersistenceCoordinator>(
      persistenceCoordinator,
      dispose: (coordinator) => coordinator.dispose(),
    );
  }
  final fileSendController = FileSendController(terminal: controller);
  final receiveLogController = ReceiveLogController(terminal: controller);
  final waveformController = WaveformController(terminal: controller);
  final ispController = IspController(
    terminal: controller,
    multiSendController: multiSendController,
    fileSendController: fileSendController,
    firmwareBytesReader: ispFirmwareReader,
  );
  container.registerSingleton<FileSendController>(
    fileSendController,
    dispose: (controller) => controller.dispose(),
  );
  container.registerSingleton<ReceiveLogController>(
    receiveLogController,
    dispose: (controller) => controller.dispose(),
  );
  container.registerSingleton<WaveformController>(
    waveformController,
    dispose: (controller) => controller.dispose(),
  );
  container.registerSingleton<IspController>(
    ispController,
    dispose: (controller) => controller.dispose(),
  );
  final settingsMigrationController =
      settingsRepository != null &&
          settingsBackupDirectory != null &&
          persistenceCoordinator != null
      ? SettingsMigrationController(
          coordinator: persistenceCoordinator,
          backupDirectory: settingsBackupDirectory,
          fileReader: legacyIniReader,
        )
      : null;
  if (settingsMigrationController != null) {
    container.registerSingleton<SettingsMigrationController>(
      settingsMigrationController,
      dispose: (controller) => controller.dispose(),
    );
  }
  container.registerLazySingleton<GoRouter>(
    () => createAppRouter(
      controller: controller,
      fileSendController: fileSendController,
      receiveLogController: receiveLogController,
      multiSendController: multiSendController,
      waveformController: waveformController,
      ispController: ispController,
      settingsMigrationController: settingsMigrationController,
      pickIspFirmware: pickIspFirmware ?? pickIspFirmwareDefault,
      pickLegacyIni: pickLegacyIni ?? pickLegacyIniDefault,
      supportReleaseInfoLoader: supportReleaseInfoLoader ?? loadAppReleaseInfo,
    ),
    dispose: (router) => router.dispose(),
  );
  return controller;
}
