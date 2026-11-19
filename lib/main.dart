import 'dart:io';

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/bootstrap.dart';
import 'features/settings/domain/app_settings.dart';
import 'features/settings/infrastructure/json_settings_repository.dart';
import 'features/settings/infrastructure/settings_bootstrap.dart';

/// 初始化应用依赖并启动 Flutter。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  late final SettingsBootstrapResult result;
  JsonSettingsRepository? settingsRepository;
  Directory? settingsBackupDirectory;
  try {
    final runtime = await createDefaultSettingsRuntime();
    settingsBackupDirectory = runtime.bootstrapService.backupDirectory;
    result = await runtime.bootstrapService.loadOrMigrate();
    if (result.persistenceEnabled) {
      settingsRepository = runtime.repository;
    }
  } catch (error) {
    // 设置目录或文件系统不可用时仍以安全默认值启动；关闭持久化并在界面中
    // 显示可操作提示，避免启动异常直接终止进程。
    result = SettingsBootstrapResult(
      settings: AppSettings.defaults(),
      persistenceEnabled: false,
      notices: <String>['设置存储初始化失败，本次使用安全默认值：$error'],
    );
  }
  final notice = result.notices.isEmpty ? null : result.notices.join('\n');
  final dependencies = await bootstrap(
    settingsRepository: settingsRepository,
    settingsBackupDirectory: settingsBackupDirectory,
    settings: result.settings,
    initialNotice: notice,
  );
  runApp(App(dependencies: dependencies));
}
