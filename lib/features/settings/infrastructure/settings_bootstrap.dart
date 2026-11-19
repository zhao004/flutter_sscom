import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../domain/app_settings.dart';
import '../infrastructure/json_settings_repository.dart';
import '../infrastructure/legacy_ini_migrator.dart';

/// 新版设置目录名称。
const String settingsDirectoryName = 'SSCOM';

/// 新版设置文件名。
const String settingsFileName = 'settings.json';

/// 启动设置加载或迁移结果。
final class SettingsBootstrapResult {
  /// 创建结果。
  SettingsBootstrapResult({
    required this.settings,
    required this.persistenceEnabled,
    required List<String> notices,
  }) : notices = List<String>.unmodifiable(notices);

  final AppSettings settings;
  final bool persistenceEnabled;
  final List<String> notices;
}

/// 首次启动设置加载和旧 INI 自动迁移服务。
final class SettingsBootstrapService {
  /// 创建服务。
  SettingsBootstrapService({
    required this.repository,
    required this.backupDirectory,
    required this.legacyIniLocator,
    this.migrator = const LegacyIniMigrator(),
  });

  final SettingsRepository repository;
  final Directory backupDirectory;
  final LegacyIniLocator legacyIniLocator;
  final LegacyIniMigrator migrator;

  /// 加载设置；主设置不存在时尝试一次性迁移旧 INI。
  Future<SettingsBootstrapResult> loadOrMigrate() async {
    final notices = <String>[];
    AppSettings? existing;
    try {
      existing = await repository.load();
    } catch (error) {
      notices.add('设置读取失败，本次使用安全默认值：$error');
      return SettingsBootstrapResult(
        settings: AppSettings.defaults(),
        persistenceEnabled: false,
        notices: notices,
      );
    }
    if (existing != null) {
      return SettingsBootstrapResult(
        settings: existing,
        persistenceEnabled: true,
        notices: const <String>[],
      );
    }

    File? legacyFile;
    try {
      legacyFile = await legacyIniLocator.locate();
    } catch (error) {
      notices.add('旧配置查找失败，本次使用安全默认值：$error');
      return SettingsBootstrapResult(
        settings: AppSettings.defaults(),
        persistenceEnabled: true,
        notices: notices,
      );
    }
    if (legacyFile == null) {
      return SettingsBootstrapResult(
        settings: AppSettings.defaults(),
        persistenceEnabled: true,
        notices: const <String>[],
      );
    }

    late final Uint8List bytes;
    late final LegacyIniMigrationResult migration;
    try {
      bytes = await legacyFile.readAsBytes();
      migration = migrator.migrate(
        bytes,
        sourceName: legacyFile.uri.pathSegments.last,
      );
    } catch (error) {
      notices.add('旧配置读取或解析失败，本次使用安全默认值：$error');
      return SettingsBootstrapResult(
        settings: AppSettings.defaults(),
        persistenceEnabled: true,
        notices: notices,
      );
    }
    notices.addAll(
      migration.warnings.map(
        (warning) => '旧配置 ${warning.code.id}: ${warning.message}',
      ),
    );

    try {
      await backupDirectory.create(recursive: true);
      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final backupFile = File(
        '${backupDirectory.path}${Platform.pathSeparator}'
        '${legacyFile.uri.pathSegments.last}.$timestamp.bak',
      );
      await backupFile.writeAsBytes(bytes, flush: true);
    } catch (error) {
      notices.add('旧配置备份失败，已在新版中临时加载迁移结果但不写入磁盘：$error');
      return SettingsBootstrapResult(
        settings: migration.settings,
        persistenceEnabled: false,
        notices: notices,
      );
    }

    try {
      await repository.save(migration.settings);
    } catch (error) {
      notices.add('迁移设置保存失败，本次仅使用内存结果：$error');
      return SettingsBootstrapResult(
        settings: migration.settings,
        persistenceEnabled: false,
        notices: notices,
      );
    }

    notices.add(
      '已从 ${legacyFile.uri.pathSegments.last} 迁移 ${migration.warnings.length} 条警告',
    );
    return SettingsBootstrapResult(
      settings: migration.settings,
      persistenceEnabled: true,
      notices: notices,
    );
  }
}

/// 在指定目录中查找旧版 INI。
final class LegacyIniLocator {
  /// 创建定位器。
  const LegacyIniLocator(this.directories);

  /// 搜索目录顺序。
  final List<Directory> directories;

  /// 返回首个存在的 `sscom51.ini`。
  Future<File?> locate() async {
    for (final directory in directories) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}sscom51.ini',
      );
      if (await file.exists()) {
        return file;
      }
    }
    return null;
  }
}

/// 默认 Windows 设置运行环境。
final class SettingsRuntime {
  /// 创建设置运行环境。
  const SettingsRuntime({
    required this.repository,
    required this.bootstrapService,
  });

  final JsonSettingsRepository repository;
  final SettingsBootstrapService bootstrapService;
}

/// 解析新版设置目录。
///
/// Windows 优先使用 `%APPDATA%\SSCOM`，避免 path_provider 依据 exe 版本信息
/// 生成的 company/product 子目录与规划路径不一致；环境变量不可用时回退到
/// path_provider 的应用支持目录，便于非 Windows 宿主和测试运行。
Future<Directory> resolveSettingsDirectory({
  required bool isWindows,
  required String? windowsAppDataPath,
  required Future<Directory> Function() supportDirectoryProvider,
}) async {
  final normalizedAppDataPath = windowsAppDataPath?.trim();
  if (isWindows &&
      normalizedAppDataPath != null &&
      normalizedAppDataPath.isNotEmpty) {
    return Directory(_joinPath(normalizedAppDataPath, settingsDirectoryName));
  }

  final supportDirectory = await supportDirectoryProvider();
  final segments = supportDirectory.path
      .replaceAll(RegExp(r'[\\/]+$'), '')
      .split(RegExp(r'[\\/]'));
  if (segments.isNotEmpty && segments.last == settingsDirectoryName) {
    return supportDirectory;
  }
  return Directory(_joinPath(supportDirectory.path, settingsDirectoryName));
}

/// 创建基于应用数据目录的默认设置运行环境。
Future<SettingsRuntime> createDefaultSettingsRuntime({
  bool? isWindows,
  String? windowsAppDataPath,
  Future<Directory> Function()? supportDirectoryProvider,
}) async {
  final appDirectory = await resolveSettingsDirectory(
    isWindows: isWindows ?? Platform.isWindows,
    windowsAppDataPath: windowsAppDataPath ?? Platform.environment['APPDATA'],
    supportDirectoryProvider:
        supportDirectoryProvider ?? getApplicationSupportDirectory,
  );
  await appDirectory.create(recursive: true);
  final repository = JsonSettingsRepository(
    File(_joinPath(appDirectory.path, settingsFileName)),
  );
  final backupDirectory = Directory(
    _joinPath(appDirectory.path, 'migration-backup'),
  );
  final executableDirectory = File(Platform.resolvedExecutable).parent;
  return SettingsRuntime(
    repository: repository,
    bootstrapService: SettingsBootstrapService(
      repository: repository,
      backupDirectory: backupDirectory,
      legacyIniLocator: LegacyIniLocator(<Directory>[
        Directory.current,
        executableDirectory,
      ]),
    ),
  );
}

String _joinPath(String parent, String child) {
  final normalizedParent = parent.replaceAll(RegExp(r'[\\/]+$'), '');
  final base = normalizedParent.isEmpty ? parent : normalizedParent;
  return '$base${Platform.pathSeparator}$child';
}
