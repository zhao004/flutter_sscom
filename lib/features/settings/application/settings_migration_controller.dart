import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:signals/signals.dart';

import '../infrastructure/legacy_ini_migrator.dart';
import 'settings_persistence_coordinator.dart';

/// 手动迁移允许读取的最大旧 INI 字节数。
const int maxLegacyIniFileBytes = 4 * 1024 * 1024;

/// 读取旧 INI 字节；测试可注入内存内容。
typedef LegacyIniBytesReader = Future<Uint8List> Function(File file);

Future<Uint8List> _readLegacyIniFile(File file) async {
  if (await file.length() > maxLegacyIniFileBytes) {
    throw const FormatException('旧配置文件超过允许的 4 MiB 上限');
  }
  return file.readAsBytes();
}

const Object _notSet = Object();

/// 手动配置迁移阶段。
enum SettingsMigrationPhase {
  /// 等待选择文件。
  idle,

  /// 正在读取和解析。
  reading,

  /// 已生成预览，等待确认。
  preview,

  /// 正在备份并保存。
  saving,

  /// 已保存，等待重启。
  completed,

  /// 读取、安全检查或保存失败。
  failed,
}

/// 配置迁移向导状态。
final class SettingsMigrationState {
  /// 创建迁移状态。
  SettingsMigrationState({
    this.phase = SettingsMigrationPhase.idle,
    this.sourcePath,
    this.sourceName,
    this.result,
    this.backupPath,
    this.message,
    this.errorMessage,
  });

  /// 当前阶段。
  final SettingsMigrationPhase phase;

  /// 源文件路径。
  final String? sourcePath;

  /// 源文件名。
  final String? sourceName;

  /// 解析结果。
  final LegacyIniMigrationResult? result;

  /// 原始文件备份路径。
  final String? backupPath;

  /// 非致命说明。
  final String? message;

  /// 面向用户的错误。
  final String? errorMessage;

  /// 是否正在执行文件或保存操作。
  bool get isBusy =>
      phase == SettingsMigrationPhase.reading ||
      phase == SettingsMigrationPhase.saving;

  /// 是否具备可保存的预览结果。
  bool get hasPreview => result != null;

  /// 返回替换部分字段后的状态。
  SettingsMigrationState copyWith({
    SettingsMigrationPhase? phase,
    Object? sourcePath = _notSet,
    Object? sourceName = _notSet,
    Object? result = _notSet,
    Object? backupPath = _notSet,
    Object? message = _notSet,
    Object? errorMessage = _notSet,
  }) {
    return SettingsMigrationState(
      phase: phase ?? this.phase,
      sourcePath: identical(sourcePath, _notSet)
          ? this.sourcePath
          : sourcePath as String?,
      sourceName: identical(sourceName, _notSet)
          ? this.sourceName
          : sourceName as String?,
      result: identical(result, _notSet)
          ? this.result
          : result as LegacyIniMigrationResult?,
      backupPath: identical(backupPath, _notSet)
          ? this.backupPath
          : backupPath as String?,
      message: identical(message, _notSet) ? this.message : message as String?,
      errorMessage: identical(errorMessage, _notSet)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }
}

/// 配置迁移向导控制器。
///
/// 手动迁移采用“保存后重启”策略：预览阶段只读取源文件，应用阶段先备份原始
/// 字节，再由设置持久化协调器保存新的 JSON 并暂停旧运行实例的自动保存。
final class SettingsMigrationController {
  /// 创建迁移控制器。
  SettingsMigrationController({
    required this.coordinator,
    required this.backupDirectory,
    this.migrator = const LegacyIniMigrator(),
    LegacyIniBytesReader? fileReader,
    DateTime Function()? now,
    this.maxSourceBytes = maxLegacyIniFileBytes,
  }) : _fileReader = fileReader ?? _readLegacyIniFile,
       _now = now ?? DateTime.now,
       _state = signal<SettingsMigrationState>(SettingsMigrationState()) {
    _readonlyState = _state.readonly();
  }

  /// 设置持久化协调器。
  final SettingsPersistenceCoordinator coordinator;

  /// 原始旧配置备份目录。
  final Directory backupDirectory;

  /// 旧 INI 解析器。
  final LegacyIniMigrator migrator;

  /// 手动迁移允许读取的最大字节数。
  final int maxSourceBytes;

  final LegacyIniBytesReader _fileReader;
  final DateTime Function() _now;
  final Signal<SettingsMigrationState> _state;
  late final ReadonlySignal<SettingsMigrationState> _readonlyState;
  Uint8List? _sourceBytes;
  bool _disposed = false;

  /// 只读迁移状态。
  ReadonlySignal<SettingsMigrationState> get state => _readonlyState;

  /// 当前终端工作区，用于显示和应用前安全检查。
  TerminalController get terminal => coordinator.controller;

  /// 是否可以在当前会话应用迁移。
  bool get isSessionSafe => _sessionBlockReason() == null;

  /// 读取并预览旧 INI，不写入源文件或设置目录。
  Future<void> inspectFile(File file) async {
    _throwIfDisposed();
    if (_state.value.isBusy) {
      return;
    }
    if (coordinator.isSuspended) {
      _state.value = _state.value.copyWith(
        phase: SettingsMigrationPhase.completed,
        errorMessage: '设置已经保存，请先重启应用再执行新的迁移',
      );
      return;
    }

    final sourceName = _fileName(file.path);
    _sourceBytes = null;
    _state.value = SettingsMigrationState(
      phase: SettingsMigrationPhase.reading,
      sourcePath: file.path,
      sourceName: sourceName,
      message: '正在读取并解析旧配置',
    );
    try {
      final bytes = await _fileReader(file);
      if (bytes.length > maxSourceBytes) {
        throw const FormatException('旧配置文件超过允许的大小上限');
      }
      final result = migrator.migrate(bytes, sourceName: sourceName);
      _sourceBytes = bytes;
      _state.value = _state.value.copyWith(
        phase: SettingsMigrationPhase.preview,
        result: result,
        message:
            '预览已生成：${result.warnings.length} 条警告，'
            '${result.unknownEntries.length} 个未知键',
        errorMessage: null,
      );
    } catch (error) {
      _sourceBytes = null;
      _state.value = _state.value.copyWith(
        phase: SettingsMigrationPhase.failed,
        result: null,
        errorMessage: _messageFor(error),
      );
    }
  }

  /// 备份原始文件并保存迁移设置；成功后必须重启应用才能生效。
  Future<void> apply() async {
    _throwIfDisposed();
    if (_state.value.isBusy) {
      return;
    }
    if (coordinator.isSuspended) {
      _state.value = _state.value.copyWith(
        phase: SettingsMigrationPhase.completed,
        errorMessage: '设置已经保存，请先重启应用',
      );
      return;
    }
    final result = _state.value.result;
    final bytes = _sourceBytes;
    if (result == null || bytes == null) {
      _state.value = _state.value.copyWith(
        phase: SettingsMigrationPhase.failed,
        errorMessage: '请先选择并解析旧配置文件',
      );
      return;
    }

    final blockReason = _sessionBlockReason();
    if (blockReason != null) {
      _state.value = _state.value.copyWith(
        phase: SettingsMigrationPhase.failed,
        errorMessage: blockReason,
      );
      return;
    }

    _state.value = _state.value.copyWith(
      phase: SettingsMigrationPhase.saving,
      message: '正在备份原始配置并保存迁移结果',
      errorMessage: null,
    );
    try {
      await backupDirectory.create(recursive: true);
      final timestamp = _now().toUtc().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final safeName = (_state.value.sourceName ?? 'sscom51.ini').replaceAll(
        RegExp(r'[^A-Za-z0-9._-]'),
        '_',
      );
      final backupFile = File(
        '${backupDirectory.path}${Platform.pathSeparator}'
        '$safeName.$timestamp.bak',
      );
      await backupFile.writeAsBytes(bytes, flush: true);
      await coordinator.replaceForRestart(result.settings);

      _state.value = _state.value.copyWith(
        phase: SettingsMigrationPhase.completed,
        backupPath: backupFile.path,
        message: '迁移设置已保存。请退出并重新启动 SSCOM 以应用新设置。',
        errorMessage: null,
      );
    } catch (error) {
      _state.value = _state.value.copyWith(
        phase: SettingsMigrationPhase.failed,
        errorMessage: _messageFor(error),
      );
    }
  }

  /// 清除当前预览；已完成的迁移结果不能被撤销。
  void reset() {
    _throwIfDisposed();
    if (_state.value.isBusy || coordinator.isSuspended) {
      return;
    }
    _sourceBytes = null;
    _state.value = SettingsMigrationState();
  }

  /// 释放迁移状态信号。
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _sourceBytes = null;
    _state.dispose();
  }

  String? _sessionBlockReason() {
    final terminalState = terminal.state.value;
    if (terminalState.isTransportActive ||
        terminalState.isOpening ||
        terminalState.isSending ||
        terminalState.isExclusiveSend) {
      return '请先断开串口或网络连接，并结束 ISP 会话后再迁移配置';
    }
    if (coordinator.multiSendController?.state.value.isRunning == true) {
      return '请先停止多字符串发送后再迁移配置';
    }
    return null;
  }

  String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  String _messageFor(Object error) {
    return switch (error) {
      FileSystemException() => '文件操作失败：${error.message}',
      FormatException() => error.message,
      StateError() => error.message,
      ArgumentError() => error.message ?? error.toString(),
      _ => error.toString(),
    };
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('SettingsMigrationController 已销毁');
    }
  }
}
