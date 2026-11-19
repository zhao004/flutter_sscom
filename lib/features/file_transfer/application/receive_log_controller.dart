import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:signals/signals.dart';

import '../infrastructure/receive_log_writer.dart';
import '../../terminal/application/terminal_controller.dart';

/// 接收落盘状态。
final class ReceiveLogState {
  /// 创建接收落盘状态。
  const ReceiveLogState({
    this.isLogging = false,
    this.filePath,
    this.bytesWritten = 0,
    this.errorMessage,
  });

  /// 是否正在记录接收数据。
  final bool isLogging;

  /// 当前日志文件路径。
  final String? filePath;

  /// 已成功写入的字节数。
  final int bytesWritten;

  /// 最近一次失败说明。
  final String? errorMessage;

  /// 返回替换部分字段后的状态。
  ReceiveLogState copyWith({
    bool? isLogging,
    String? filePath,
    int? bytesWritten,
    String? errorMessage,
  }) {
    return ReceiveLogState(
      isLogging: isLogging ?? this.isLogging,
      filePath: filePath ?? this.filePath,
      bytesWritten: bytesWritten ?? this.bytesWritten,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// 将完整接收流顺序写入用户选择的文件。
final class ReceiveLogController {
  /// 创建接收落盘控制器。
  ReceiveLogController({
    required this.terminal,
    this.maxPendingBytes = 4 * 1024 * 1024,
  }) : assert(maxPendingBytes > 0),
       _state = signal<ReceiveLogState>(const ReceiveLogState()) {
    _readonlyState = _state.readonly();
    _subscription = terminal.receivedData.listen(_handleReceivedData);
  }

  /// 接收数据来源。
  final TerminalController terminal;

  /// 等待磁盘写入的最大字节数。
  final int maxPendingBytes;

  final Signal<ReceiveLogState> _state;
  late final ReadonlySignal<ReceiveLogState> _readonlyState;
  StreamSubscription<Uint8List>? _subscription;
  ReceiveLogWriter? _writer;
  int _bytesWritten = 0;
  bool _disposed = false;

  /// 只读落盘状态。
  ReadonlySignal<ReceiveLogState> get state => _readonlyState;

  /// 开始追加接收数据到文件。
  Future<void> start(File file, {bool append = true}) async {
    _throwIfDisposed();
    if (_writer != null) {
      await stop();
    }
    final writer = ReceiveLogWriter(
      file: file,
      maxPendingBytes: maxPendingBytes,
    );
    try {
      await writer.open(append: append);
    } catch (error) {
      _state.value = ReceiveLogState(
        filePath: file.path,
        errorMessage: '无法打开接收日志：$error',
      );
      return;
    }
    _writer = writer;
    _bytesWritten = 0;
    _state.value = ReceiveLogState(isLogging: true, filePath: file.path);
  }

  /// 停止记录并等待队列中的写入完成。
  Future<void> stop() {
    final writer = _writer;
    _writer = null;
    if (writer == null) {
      if (_state.value.isLogging) {
        _state.value = ReceiveLogState(
          filePath: _state.value.filePath,
          bytesWritten: _bytesWritten,
        );
      }
      return Future<void>.value();
    }
    return _closeWriter(writer);
  }

  Future<void> _closeWriter(ReceiveLogWriter writer) async {
    try {
      await writer.close();
      _state.value = ReceiveLogState(
        filePath: writer.file.path,
        bytesWritten: _bytesWritten,
      );
    } catch (error) {
      _state.value = ReceiveLogState(
        filePath: writer.file.path,
        bytesWritten: _bytesWritten,
        errorMessage: '接收日志关闭失败：$error',
      );
    }
  }

  /// 停止接收并释放状态信号。
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    await _subscription?.cancel();
    _subscription = null;
    final writer = _writer;
    _writer = null;
    if (writer == null) {
      if (_state.value.isLogging) {
        _state.value = ReceiveLogState(
          filePath: _state.value.filePath,
          bytesWritten: _bytesWritten,
        );
      }
    } else {
      await _closeWriter(writer);
    }
    _disposed = true;
    _state.dispose();
  }

  void _handleReceivedData(Uint8List bytes) {
    final writer = _writer;
    if (writer == null || _disposed) {
      return;
    }
    unawaited(_write(writer, bytes));
  }

  Future<void> _write(ReceiveLogWriter writer, Uint8List bytes) async {
    try {
      await writer.append(bytes);
      _bytesWritten += bytes.length;
      if (identical(_writer, writer) && !_disposed) {
        _state.value = _state.value.copyWith(bytesWritten: _bytesWritten);
      }
    } catch (error) {
      if (identical(_writer, writer)) {
        _writer = null;
        if (!_disposed) {
          _state.value = ReceiveLogState(
            filePath: writer.file.path,
            bytesWritten: _bytesWritten,
            errorMessage: '接收日志写入失败：$error',
          );
        }
        try {
          await writer.close();
        } catch (_) {
          // 原始写入错误已经暴露，关闭失败不能覆盖用户可见原因。
        }
      }
    }
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('ReceiveLogController 已销毁');
    }
  }
}
