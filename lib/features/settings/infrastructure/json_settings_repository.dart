import 'dart:convert';
import 'dart:io';

import '../domain/app_settings.dart';

/// 设置读写契约。
abstract interface class SettingsRepository {
  /// 读取设置；文件不存在时返回 `null`。
  Future<AppSettings?> load();

  /// 持久化完整设置快照。
  Future<void> save(AppSettings settings);
}

/// 设置存储失败。
final class SettingsRepositoryException implements Exception {
  /// 创建设置存储异常。
  const SettingsRepositoryException(this.message, {this.cause});

  /// 面向用户或日志的说明。
  final String message;

  /// 可选底层异常。
  final Object? cause;

  @override
  String toString() => 'SettingsRepositoryException: $message';
}

/// 使用 UTF-8 JSON 文件和同目录临时文件保存设置。
final class JsonSettingsRepository implements SettingsRepository {
  /// 创建 JSON 仓库。
  JsonSettingsRepository(this.file);

  /// 正式设置文件。
  final File file;

  /// 最近一次旧设置备份。
  File get backupFile => File('${file.path}.bak');

  /// 写入中的临时文件。
  File get temporaryFile => File('${file.path}.tmp');

  Future<void> _pending = Future<void>.value();

  @override
  Future<AppSettings?> load() async {
    try {
      if (!await file.exists()) {
        final backup = backupFile;
        if (!await backup.exists()) {
          return null;
        }
        await file.parent.create(recursive: true);
        await backup.copy(file.path);
      }
      final text = await file.readAsString(encoding: utf8);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('设置根节点必须是 JSON 对象');
      }
      return AppSettings.fromJson(decoded);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        SettingsRepositoryException('无法读取设置文件 ${file.path}', cause: error),
        stackTrace,
      );
    }
  }

  @override
  Future<void> save(AppSettings settings) {
    final text = const JsonEncoder.withIndent('  ').convert(settings.toJson());
    final operation = _pending.then((_) => _write(text));
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _write(String text) async {
    final parent = file.parent;
    await parent.create(recursive: true);
    final temporary = temporaryFile;
    final backup = backupFile;
    try {
      await temporary.writeAsString(text, encoding: utf8, flush: true);

      var hadOriginal = false;
      if (await file.exists()) {
        if (await backup.exists()) {
          await backup.delete();
        }
        await file.rename(backup.path);
        hadOriginal = true;
      }

      try {
        await temporary.rename(file.path);
      } catch (error, stackTrace) {
        if (hadOriginal && !await file.exists() && await backup.exists()) {
          await backup.rename(file.path);
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    } catch (error, stackTrace) {
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } catch (_) {
          // 清理失败不能遮蔽原始写入错误。
        }
      }
      Error.throwWithStackTrace(
        SettingsRepositoryException('无法保存设置文件 ${file.path}', cause: error),
        stackTrace,
      );
    }
  }
}
