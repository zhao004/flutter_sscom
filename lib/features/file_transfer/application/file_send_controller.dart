import 'dart:io';

import 'package:signals/signals.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';

/// 文件发送阶段。
enum FileSendPhase {
  /// 尚未开始或已重置。
  idle,

  /// 正在读取并发送文件。
  running,

  /// 文件字节已全部发送。
  completed,

  /// 用户取消了发送。
  cancelled,

  /// 文件、连接或传输失败。
  failed,
}

/// 文件发送的只读状态。
final class FileSendState {
  /// 创建文件发送状态。
  const FileSendState({
    required this.phase,
    this.filePath,
    this.fileName,
    this.totalBytes = 0,
    this.sentBytes = 0,
    this.errorMessage,
  });

  /// 文件发送是否正在运行。
  bool get isRunning => phase == FileSendPhase.running;

  /// 已发送字节比例，范围为 0 到 1。
  double get progress {
    if (totalBytes <= 0) {
      return 0;
    }
    return (sentBytes / totalBytes).clamp(0, 1);
  }

  /// 当前阶段。
  final FileSendPhase phase;

  /// 源文件绝对路径。
  final String? filePath;

  /// 源文件名。
  final String? fileName;

  /// 源文件总字节数。
  final int totalBytes;

  /// 已接受的字节数。
  final int sentBytes;

  /// 失败时的用户可读说明。
  final String? errorMessage;
}

/// 将文件分块写入串口传输层。
///
/// 文件发送不经过终端输入编码和校验追加，适合固件、日志等二进制文件。每次
/// 读取只保留一个分块，发送进度通过状态信号驱动表现层；取消受阻发送时
/// 关闭连接，以解除传输层等待并回收文件句柄。
final class FileSendController {
  /// 创建文件发送控制器。
  FileSendController({required this.terminal, this.chunkSize = 4096})
    : assert(chunkSize > 0),
      _state = signal<FileSendState>(
        const FileSendState(phase: FileSendPhase.idle),
      ) {
    _readonlyState = _state.readonly();
  }

  /// 发送操作使用的终端控制器。
  final TerminalController terminal;

  /// 每次读取并发送的最大字节数。
  final int chunkSize;

  final Signal<FileSendState> _state;
  late final ReadonlySignal<FileSendState> _readonlyState;
  Future<void>? _operation;
  bool _cancelRequested = false;
  bool _sendingChunk = false;
  bool _disposed = false;

  /// 只读发送状态。
  ReadonlySignal<FileSendState> get state => _readonlyState;

  /// 开始发送文件；已有发送任务时直接返回同一个任务。
  Future<void> start(File file) {
    _throwIfDisposed();
    final active = _operation;
    if (active != null) {
      return active;
    }
    final operation = _run(file);
    _operation = operation;
    return operation.whenComplete(() {
      if (identical(_operation, operation)) {
        _operation = null;
      }
    });
  }

  /// 取消文件发送；存在正在发送的分块时会关闭连接以中止等待。
  Future<void> cancel() async {
    _cancelRequested = true;
    if (_sendingChunk) {
      await terminal.close();
    }
    await _operation;
  }

  /// 停止任务并释放状态信号。
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    try {
      await cancel();
    } finally {
      _disposed = true;
      _state.dispose();
    }
  }

  Future<void> _run(File file) async {
    _cancelRequested = false;
    final fileName = file.uri.pathSegments.isEmpty
        ? file.path
        : file.uri.pathSegments.last;
    RandomAccessFile? handle;
    var sentBytes = 0;
    var totalBytes = 0;
    try {
      if (!terminal.state.value.isConnected) {
        throw StateError('连接未建立，不能发送文件');
      }
      if (terminal.state.value.isExclusiveSend) {
        throw StateError('串口正被 ISP 等独占流程使用，不能发送文件');
      }
      totalBytes = await file.length();
      final initialModified = await file.lastModified();
      if (totalBytes <= 0) {
        throw StateError('文件为空，无法发送');
      }
      _state.value = FileSendState(
        phase: FileSendPhase.running,
        filePath: file.path,
        fileName: fileName,
        totalBytes: totalBytes,
      );
      handle = await file.open(mode: FileMode.read);
      while (true) {
        if (_cancelRequested) {
          _state.value = FileSendState(
            phase: FileSendPhase.cancelled,
            filePath: file.path,
            fileName: fileName,
            totalBytes: totalBytes,
            sentBytes: sentBytes,
          );
          return;
        }
        final chunk = await handle.read(chunkSize);
        if (_cancelRequested) {
          continue;
        }
        if (chunk.isEmpty) {
          break;
        }
        _sendingChunk = true;
        final result = await terminal.sendBytes(chunk).whenComplete(() {
          _sendingChunk = false;
        });
        if (result == null) {
          throw StateError(terminal.state.value.errorMessage ?? '文件分块发送失败');
        }
        sentBytes += result.acceptedLength;
        _state.value = FileSendState(
          phase: FileSendPhase.running,
          filePath: file.path,
          fileName: fileName,
          totalBytes: totalBytes,
          sentBytes: sentBytes,
        );
      }

      final finalLength = await file.length();
      final finalModified = await file.lastModified();
      if (finalLength != totalBytes || finalModified != initialModified) {
        throw StateError('文件在发送过程中发生变化，请重新选择文件');
      }
      _state.value = FileSendState(
        phase: FileSendPhase.completed,
        filePath: file.path,
        fileName: fileName,
        totalBytes: totalBytes,
        sentBytes: sentBytes,
      );
    } catch (error) {
      _state.value = FileSendState(
        phase: _cancelRequested
            ? FileSendPhase.cancelled
            : FileSendPhase.failed,
        filePath: file.path,
        fileName: fileName,
        totalBytes: totalBytes,
        sentBytes: sentBytes,
        errorMessage: _cancelRequested ? null : _messageFor(error),
      );
    } finally {
      await handle?.close();
    }
  }

  String _messageFor(Object error) {
    return switch (error) {
      FileSystemException() => error.message,
      StateError() => error.message,
      _ => error.toString(),
    };
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('FileSendController 已销毁');
    }
  }
}
